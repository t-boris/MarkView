/*
 * app.js: the prototype runtime, written by MarkView. Screens are files screens/<id>.js that call App.register.
 *
 * App.register({id, route, title, render(ctx)})
 *   route: the plan's hash route, such as '/tickets' or '/tickets/:id'. render(ctx) returns an element, an HTML
 *   string or a promise of either. ctx = {params, query, user, proto: {empty, error}, embedded, refresh()}.
 * App.h(tag, attrs, ...children) -> element. attrs: class (string or array), style (string or object), dataset,
 *   on<Event> handlers (onClick, onInput, onChange, onSubmit, onKeyDown...), value, checked, disabled, html (innerHTML),
 *   any other attribute. children: strings, numbers, elements, arrays; null, false and true are skipped.
 * App.navigate(path)            goes to a hash route: App.navigate('/tickets/' + id). Links may use href="#/tickets".
 * App.refresh()                 renders the current screen again (after a change made outside its own handlers).
 * App.toast(message, kind)      kind: 'info' (default), 'success', 'warning' or 'error'.
 * App.modal({title, body, actions, wide}) -> {close(), element}. body: element or HTML string. actions:
 *   [{label, kind: 'primary' | 'danger' | 'ghost', onClick(close)}]; an onClick returning false keeps the modal open;
 *   without actions a Close button is shown. Escape and a click outside close it.
 * App.confirm(message, {title, confirmLabel, danger}) -> Promise<boolean>.
 * App.load(fn) -> element: shows the skeleton for about 350 ms, then what fn() returns (element, string or promise).
 *   With "Force error state" on it shows an error card with Retry instead; use it for every list or detail load.
 * App.empty({title, text, action: {label, onClick}}) -> element of class "empty" for an empty list or search.
 * App.addStyles(css)            adds the screen's own CSS (once per call site; scope it under the screen's class).
 * App.user() -> {name, role}. App.roles -> the plan's role names. App.setRole(role).
 * App.allow(role, [permissions]) grants permissions to a role. App.can(permission) is true when the current role has
 *   it, or when no role was granted it at all. Declare the grants of your screen at the top of its file.
 * App.proto() -> {empty, error}: the Prototype menu's "Force empty state" and "Force error state". With empty on,
 *   DB.list and DB.all return nothing, so a list shows its empty state by itself.
 * App.format.date(value), .dateTime(value), .relative(value), .money(amount, currency), .number(n), .percent(n).
 * App.store(key[, value]) reads or writes a small piece of UI state that survives a reload (filters, tabs).
 * App.plan -> [{id, name, route, embedded, hosts}]. App.title. App.renderScreen(id, extra) -> element.
 *
 * The shell (header with the title, the "Signed in as" role switch and the Prototype menu, navigation built from the
 * plan, toasts and modals) uses the classes of styles.css: app-shell, app-header, app-title, app-nav, app-main,
 * btn btn-primary btn-ghost btn-danger, card card-header card-body, table, form field input select field-error,
 * badge, tabs tab is-active, toolbar, modal modal-card modal-actions, toast toast-<kind>, skeleton, empty, pagination.
 */
(function () {
  'use strict';
  var App = window.App = window.App || {};
  var config = { title: document.title || 'Prototype', plan: [], roles: ['User'] };
  var screens = {}, order = [], grants = {}, started = false, token = 0, shell = null;
  var meta = document.querySelector('meta[name="mv-prototype"]');
  var prefix = 'mv-proto:' + (meta ? meta.content : location.pathname) + ':';
  var names = ['Alex Morgan', 'Priya Natarajan', 'Jonas Becker', 'Maria Santos', 'Kenji Watanabe', 'Lena Novak', 'Omar Haddad', 'Chloe Martin'];

  function read(key, fallback) {
    try { var value = localStorage.getItem(prefix + key); return value == null ? fallback : JSON.parse(value); } catch (e) { return fallback; }
  }
  function write(key, value) { try { localStorage.setItem(prefix + key, JSON.stringify(value)); } catch (e) {} }

  App.configure = function (options) {
    for (var name in options || {}) config[name] = options[name];
    config.plan = (config.plan || []).map(function (entry) {
      var route = String(entry.route || '/' + entry.id).replace(/^#/, '');
      if (route.charAt(0) !== '/') route = '/' + route;
      return { id: entry.id, name: entry.name || entry.id, route: route, embedded: !!entry.embedded, hosts: entry.hosts || [] };
    });
    if (!config.roles || !config.roles.length) config.roles = ['User'];
    App.plan = config.plan;
    App.title = config.title;
    App.roles = config.roles.slice();
  };
  App.configure({});

  // MARK: elements

  function append(element, child) {
    if (child == null || child === false || child === true) return;
    if (Array.isArray(child)) { child.forEach(function (item) { append(element, item); }); return; }
    if (child instanceof Node) { element.appendChild(child); return; }
    element.appendChild(document.createTextNode(String(child)));
  }
  App.h = function (tag, attrs) {
    var element = document.createElement(tag);
    var children = Array.prototype.slice.call(arguments, 2);
    if (attrs != null && (typeof attrs !== 'object' || attrs instanceof Node || Array.isArray(attrs))) { children.unshift(attrs); attrs = null; }
    append(element, children);
    Object.keys(attrs || {}).forEach(function (name) {
      var value = attrs[name];
      if (value == null || value === false) return;
      if (/^on[A-Z]/.test(name) && typeof value === 'function') { element.addEventListener(name.slice(2).toLowerCase(), value); return; }
      if (name === 'class' || name === 'className') { element.className = Array.isArray(value) ? value.filter(Boolean).join(' ') : String(value); return; }
      if (name === 'style' && typeof value === 'object') { Object.keys(value).forEach(function (key) { element.style[key] = value[key]; }); return; }
      if (name === 'dataset' && typeof value === 'object') { Object.keys(value).forEach(function (key) { element.dataset[key] = value[key]; }); return; }
      if (name === 'html') { element.innerHTML = value; return; }
      if (name === 'value') { element.value = value; if (tag !== 'textarea' && tag !== 'select') element.setAttribute('value', value); return; }
      if (name === 'checked' || name === 'selected') { element[name] = !!value; if (value) element.setAttribute(name, ''); return; }
      element.setAttribute(name, value === true ? '' : String(value));
    });
    return element;
  };
  var h = App.h;
  function toNode(result) {
    if (result instanceof Node) return result;
    var box = document.createElement('div');
    if (result != null) box.innerHTML = String(result);
    return box;
  }

  var addedStyles = {};
  App.addStyles = function (css) {
    if (!css || addedStyles[css]) return;
    addedStyles[css] = true;
    var style = document.createElement('style');
    style.textContent = css;
    document.head.appendChild(style);
  };

  // An error inside a screen is shown in its place and reported with the screen's own file and line.
  function report(error) {
    if (window.console) console.error(error);
    var stack = String(error && error.stack || '');
    var frame = /((?:[a-z]+:\/\/[^\s)]*?)?[^\s(@]*\.js):(\d+)(?::(\d+))?/.exec(stack.split('\n').filter(function (line) { return !/\/app\.js:/.test(line); })[0] || stack) || [];
    try {
      window.dispatchEvent(new ErrorEvent('error', { message: (error && error.name ? error.name + ': ' : '') + (error && error.message || String(error)),
        filename: frame[1] || '', lineno: frame[2] ? Number(frame[2]) : 0, colno: frame[3] ? Number(frame[3]) : 0, error: error }));
    } catch (e) {}
  }
  function failure(error) {
    return h('div', { class: 'card error-card', role: 'alert' },
      h('div', { class: 'card-body' }, h('strong', null, 'This screen failed to render.'), h('p', null, String(error && error.message || error))));
  }
  function show(host, produce, mine) {
    var result;
    try { result = produce(); } catch (error) { host.appendChild(failure(error)); report(error); return; }
    if (result && typeof result.then === 'function') {
      var hold = skeleton();
      host.appendChild(hold);
      result.then(function (value) {
        if (mine != null && mine !== token) return;
        if (hold.parentNode) hold.parentNode.replaceChild(toNode(value), hold);
      }, function (error) {
        if (hold.parentNode) hold.parentNode.replaceChild(failure(error), hold);
        report(error);
      });
    } else {
      host.appendChild(toNode(result));
    }
  }

  // MARK: user, permissions and the Prototype menu

  var proto = read('proto', { empty: false, error: false });
  App.proto = function () { return { empty: !!proto.empty, error: !!proto.error }; };
  var role = read('role', null);
  App.user = function () {
    var current = config.roles.indexOf(role) >= 0 ? role : config.roles[0];
    return { name: names[Math.max(0, config.roles.indexOf(current)) % names.length], role: current };
  };
  App.setRole = function (next) { role = next; write('role', next); syncShell(); App.refresh(); };
  App.allow = function (who, permissions) {
    (Array.isArray(permissions) ? permissions : [permissions]).forEach(function (permission) {
      (grants[permission] = grants[permission] || {})[who] = true;
    });
  };
  App.can = function (permission) {
    var granted = grants[permission];
    if (!granted || !Object.keys(granted).length) return true;
    return !!granted[App.user().role];
  };

  App.store = function (key, value) {
    if (arguments.length > 1) { write('ui:' + key, value); return value; }
    return read('ui:' + key, undefined);
  };

  // MARK: feedback

  App.toast = function (message, kind) {
    var host = document.querySelector('.app-toasts');
    if (!host) { host = h('div', { class: 'app-toasts', 'aria-live': 'polite', 'data-mv-chrome': '' }); document.body.appendChild(host); }
    var item = h('div', { class: 'toast toast-' + (kind || 'info'), role: kind === 'error' ? 'alert' : 'status' }, String(message));
    host.appendChild(item);
    setTimeout(function () { item.classList.add('is-leaving'); setTimeout(function () { item.remove(); }, 250); }, kind === 'error' ? 5000 : 3200);
  };

  var modals = [];
  App.modal = function (options) {
    options = options || {};
    var overlay, card;
    function close() {
      if (!overlay.parentNode) return;
      overlay.remove();
      modals = modals.filter(function (entry) { return entry !== close; });
      if (options.onClose) options.onClose();
    }
    var actions = (options.actions && options.actions.length ? options.actions : [{ label: 'Close', kind: 'ghost' }]).map(function (action) {
      return h('button', { type: 'button', class: 'btn ' + (action.kind ? 'btn-' + action.kind : ''), disabled: action.disabled,
        onClick: function () { var keep = action.onClick ? action.onClick(close) : undefined; if (keep !== false) close(); } }, action.label);
    });
    var body = h('div', { class: 'modal-body' }, options.body instanceof Node ? options.body : toNode(options.body == null ? '' : options.body));
    card = h('div', { class: 'modal-card' + (options.wide ? ' modal-wide' : ''), role: 'dialog', 'aria-modal': 'true', 'aria-label': options.title || 'Dialog' },
      options.title ? h('div', { class: 'modal-header card-header' }, h('h2', null, options.title)) : null,
      body, h('div', { class: 'modal-actions' }, actions));
    overlay = h('div', { class: 'modal', onClick: function (event) { if (event.target === overlay) close(); } }, card);
    document.body.appendChild(overlay);
    modals.push(close);
    var focus = card.querySelector('input, select, textarea, .btn-primary, button');
    if (focus) setTimeout(function () { focus.focus(); }, 0);
    return { close: close, element: card };
  };
  App.confirm = function (message, options) {
    options = options || {};
    return new Promise(function (resolve) {
      var answered = false;
      App.modal({ title: options.title || 'Please confirm', body: h('p', null, message),
        onClose: function () { if (!answered) resolve(false); },
        actions: [{ label: 'Cancel', kind: 'ghost' },
                  { label: options.confirmLabel || 'Confirm', kind: options.danger ? 'danger' : 'primary', onClick: function () { answered = true; resolve(true); } }] });
    });
  };

  function skeleton() {
    return h('div', { class: 'skeleton-group', 'aria-busy': 'true', 'aria-label': 'Loading' },
      h('div', { class: 'skeleton skeleton-title' }), h('div', { class: 'skeleton' }), h('div', { class: 'skeleton' }), h('div', { class: 'skeleton skeleton-short' }));
  }
  App.load = function (fn) {
    var box = h('div', { class: 'app-load' });
    function run() {
      box.innerHTML = '';
      var hold = skeleton();
      box.appendChild(hold);
      var mine = token;
      setTimeout(function () {
        if (mine !== token && !box.isConnected) return;
        box.innerHTML = '';
        if (proto.error) {
          box.appendChild(h('div', { class: 'card error-card', role: 'alert' }, h('div', { class: 'card-body' },
            h('strong', null, 'Something went wrong while loading.'), h('p', null, 'The service did not answer. Try again in a moment.'),
            h('button', { type: 'button', class: 'btn btn-primary', onClick: run }, 'Retry'))));
          return;
        }
        show(box, fn, null);
      }, 350);
    }
    run();
    return box;
  };
  App.empty = function (options) {
    options = options || {};
    return h('div', { class: 'empty' }, h('strong', { class: 'empty-title' }, options.title || 'Nothing here yet'),
      options.text ? h('p', null, options.text) : null,
      options.action ? h('button', { type: 'button', class: 'btn btn-primary', onClick: options.action.onClick }, options.action.label) : null);
  };

  function date(value) { var d = value instanceof Date ? value : new Date(value); return isNaN(d) ? String(value == null ? '' : value) : d; }
  App.format = {
    date: function (value) { var d = date(value); return d instanceof Date ? d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }) : d; },
    dateTime: function (value) { var d = date(value); return d instanceof Date ? d.toLocaleString(undefined, { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }) : d; },
    relative: function (value) {
      var d = date(value); if (!(d instanceof Date)) return d;
      var minutes = Math.round((d - Date.now()) / 60000), abs = Math.abs(minutes);
      var rtf = window.Intl && Intl.RelativeTimeFormat ? new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' }) : null;
      if (!rtf) return App.format.dateTime(d);
      if (abs < 60) return rtf.format(minutes, 'minute');
      if (abs < 1440) return rtf.format(Math.round(minutes / 60), 'hour');
      if (abs < 43200) return rtf.format(Math.round(minutes / 1440), 'day');
      return App.format.date(d);
    },
    money: function (amount, currency) {
      try { return new Intl.NumberFormat(undefined, { style: 'currency', currency: currency || 'USD' }).format(Number(amount) || 0); }
      catch (e) { return (Number(amount) || 0).toFixed(2) + ' ' + (currency || ''); }
    },
    number: function (n) { return new Intl.NumberFormat().format(Number(n) || 0); },
    percent: function (n) { return new Intl.NumberFormat(undefined, { style: 'percent', maximumFractionDigits: 1 }).format(Number(n) || 0); }
  };

  // MARK: routing

  function match(route, path) {
    var want = route.split('/').filter(Boolean), have = path.split('/').filter(Boolean);
    if (want.length !== have.length) return null;
    var params = {};
    for (var i = 0; i < want.length; i++) {
      if (want[i].charAt(0) === ':') params[want[i].slice(1)] = decodeURIComponent(have[i]);
      else if (want[i] !== have[i]) return null;
    }
    return params;
  }
  function location_() {
    var hash = location.hash.replace(/^#/, '');
    var at = hash.indexOf('?'), path = at < 0 ? hash : hash.slice(0, at), query = {};
    if (at >= 0) new URLSearchParams(hash.slice(at + 1)).forEach(function (value, key) { query[key] = value; });
    return { path: path || '/', query: query };
  }
  // The registered screen whose route fits the path best (fewest parameters), else the planned entry that is not built yet.
  function resolve(path) {
    var best = null;
    order.forEach(function (id) {
      var params = match(screens[id].route, path);
      var weight = (screens[id].route.match(/:/g) || []).length;
      if (params && (!best || weight < best.weight)) best = { screen: screens[id], params: params, weight: weight };
    });
    if (best) return best;
    for (var i = 0; i < config.plan.length; i++) {
      var params = match(config.plan[i].route, path);
      if (params) return { planned: config.plan[i], params: params };
    }
    return null;
  }
  function navigable() { return config.plan.filter(function (entry) { return !entry.embedded; }); }
  function firstRoute() {
    var entries = navigable().filter(function (entry) { return entry.route.indexOf(':') < 0; });
    if (entries.length) return entries[0].route;
    return order.length ? screens[order[0]].route : null;
  }
  function context(screen, params, query, embedded) {
    return { params: params || {}, query: query || {}, user: App.user(), proto: App.proto(), embedded: !!embedded, refresh: App.refresh, screen: screen.id };
  }

  App.register = function (screen) {
    if (!screen || !screen.id) return;
    var planned = config.plan.filter(function (entry) { return entry.id === screen.id; })[0];
    var route = String(screen.route || (planned && planned.route) || '/' + screen.id).replace(/^#/, '');
    screen.route = route.charAt(0) === '/' ? route : '/' + route;
    screen.title = screen.title || (planned && planned.name) || screen.id;
    if (!screens[screen.id]) order.push(screen.id);
    screens[screen.id] = screen;
    if (started) App.refresh();
  };
  App.navigate = function (path) {
    path = String(path || '/').replace(/^#/, '');
    if (location.hash === '#' + path) App.refresh(); else location.hash = path;
  };
  App.refresh = function () {
    if (!started) return;
    var main = document.querySelector('.app-main');
    if (!main) return;
    var here = location_();
    var found = resolve(here.path);
    if (!found) {
      var first = firstRoute();
      if (first && first !== here.path) { location.replace('#' + first); return; }
    }
    var mine = ++token;
    highlight(here.path);
    while (modals.length) modals[modals.length - 1]();
    main.innerHTML = '';
    main.scrollTop = 0;
    if (!found || !found.screen) {
      var entry = found && found.planned;
      main.appendChild(h('div', { class: 'empty app-pending' }, h('strong', { class: 'empty-title' }, entry ? entry.name : 'Unknown page'),
        h('p', null, entry ? 'This screen is still being built.' : 'There is no screen at ' + here.path + '.')));
      return;
    }
    document.title = found.screen.title + ' · ' + config.title;
    main.dataset.screen = found.screen.id;
    show(main, function () { return found.screen.render(context(found.screen, found.params, here.query, false)); }, mine);
  };
  App.renderScreen = function (id, extra) {
    var box = h('div', { class: 'app-embedded', 'data-screen': id });
    var screen = screens[id];
    if (!screen) {
      var entry = config.plan.filter(function (item) { return item.id === id; })[0];
      box.appendChild(h('div', { class: 'empty app-pending' }, h('strong', { class: 'empty-title' }, entry ? entry.name : id), h('p', null, 'This part is still being built.')));
      return box;
    }
    var ctx = context(screen, {}, {}, true);
    for (var key in extra || {}) ctx[key] = extra[key];
    show(box, function () { return screen.render(ctx); }, null);
    return box;
  };

  // MARK: shell

  function highlight(path) {
    if (!shell) return;
    var best = null;
    Array.prototype.forEach.call(shell.querySelectorAll('.app-nav a'), function (link) {
      link.classList.remove('is-active');
      link.removeAttribute('aria-current');
      var route = link.getAttribute('href').slice(1);
      var fits = route === path || (route !== '/' && path.indexOf(route + '/') === 0);
      if (fits && (!best || route.length > best.getAttribute('href').length - 1)) best = link;
    });
    if (best) { best.classList.add('is-active'); best.setAttribute('aria-current', 'page'); }
    shell.classList.remove('nav-open');
  }
  function syncShell() {
    if (!shell) return;
    var select = shell.querySelector('.app-role select');
    if (select) select.value = App.user().role;
    shell.querySelector('.app-proto-empty').checked = !!proto.empty;
    shell.querySelector('.app-proto-error').checked = !!proto.error;
    shell.classList.toggle('is-forced', !!(proto.empty || proto.error));
  }
  function buildShell() {
    var entries = navigable().filter(function (entry) { return entry.route.indexOf(':') < 0; });
    var solo = navigable().length <= 1;
    var menu = h('div', { class: 'app-proto-menu card', role: 'menu', hidden: true },
      h('label', { class: 'app-proto-option' }, h('input', { type: 'checkbox', class: 'app-proto-empty', onChange: function (event) { proto.empty = event.target.checked; write('proto', proto); syncShell(); App.refresh(); } }), ' Force empty state'),
      h('label', { class: 'app-proto-option' }, h('input', { type: 'checkbox', class: 'app-proto-error', onChange: function (event) { proto.error = event.target.checked; write('proto', proto); syncShell(); App.refresh(); } }), ' Force error state'),
      h('button', { type: 'button', class: 'btn btn-ghost', onClick: function () {
        if (window.DB && DB.reset) DB.reset();
        menu.hidden = true;
        App.refresh();
        App.toast('The demo data was reset.', 'success');
      } }, 'Reset demo data'));
    var toggle = h('button', { type: 'button', class: 'btn btn-ghost app-proto-toggle', 'aria-haspopup': 'true', onClick: function (event) { event.stopPropagation(); menu.hidden = !menu.hidden; } }, 'Prototype ▾');
    document.addEventListener('click', function (event) { if (!menu.hidden && !menu.contains(event.target) && event.target !== toggle) menu.hidden = true; });
    var roleSwitch = config.roles.length > 1
      ? h('label', { class: 'app-role' }, h('span', null, 'Signed in as '),
          h('select', { class: 'select', onChange: function (event) { App.setRole(event.target.value); } },
            config.roles.map(function (name) { return h('option', { value: name }, name); })))
      : h('span', { class: 'app-role' }, App.user().name);
    var header = h('header', { class: 'app-header toolbar' },
      solo ? null : h('button', { type: 'button', class: 'app-menu-toggle', 'aria-label': 'Menu', onClick: function () { shell.classList.toggle('nav-open'); } }, '☰'),
      h('a', { class: 'app-title', href: '#' + (firstRoute() || '/') }, config.title),
      h('div', { class: 'app-header-tools' }, roleSwitch, h('div', { class: 'app-proto' }, toggle, menu)));
    var nav = solo ? null : h('nav', { class: 'app-nav', 'aria-label': 'Screens' },
      entries.map(function (entry) { return h('a', { href: '#' + entry.route }, entry.name); }));
    shell = h('div', { class: 'app-shell' + (solo ? ' app-solo' : '') }, header,
      h('div', { class: 'app-body' }, nav, h('main', { class: 'app-main', id: 'main' })));
    var root = document.getElementById('app') || document.body.appendChild(h('div', { id: 'app' }));
    root.innerHTML = '';
    root.appendChild(shell);
    syncShell();
  }

  // Layout only, at zero specificity: styles.css decides every look.
  var base = [
    ':where(.app-shell){min-height:100vh;display:flex;flex-direction:column}',
    ':where(.app-header){display:flex;align-items:center;gap:12px;padding:8px 16px}',
    ':where(.app-title){font-weight:600;text-decoration:none;color:inherit}',
    ':where(.app-header-tools){margin-left:auto;display:flex;align-items:center;gap:8px}',
    ':where(.app-body){flex:1;display:flex;min-height:0}',
    ':where(.app-nav){width:220px;flex:none;overflow:auto;display:flex;flex-direction:column}',
    ':where(.app-nav a){display:block;padding:8px 16px;text-decoration:none;color:inherit}',
    ':where(.app-main){flex:1;min-width:0;overflow:auto;padding:24px}',
    ':where(.app-solo .app-main){padding:0}',
    ':where(.app-proto){position:relative}',
    ':where(.app-proto-menu){position:absolute;right:0;top:calc(100% + 4px);z-index:60;min-width:220px;display:flex;flex-direction:column;gap:8px;padding:12px;background:Canvas;color:CanvasText;border:1px solid rgba(127,127,127,.3);border-radius:8px;box-shadow:0 8px 24px rgba(0,0,0,.18)}',
    '.app-proto-menu[hidden]{display:none}',
    ':where(.app-toasts){position:fixed;right:16px;bottom:16px;z-index:100;display:flex;flex-direction:column;gap:8px;max-width:360px}',
    ':where(.toast){padding:10px 14px;border-radius:8px;background:#222;color:#fff;box-shadow:0 6px 18px rgba(0,0,0,.2);transition:opacity .25s}',
    ':where(.toast.is-leaving){opacity:0}',
    ':where(.modal){position:fixed;inset:0;z-index:90;display:flex;align-items:center;justify-content:center;padding:16px;background:rgba(0,0,0,.45)}',
    ':where(.modal-card){width:100%;max-width:560px;max-height:90vh;overflow:auto;background:Canvas;color:CanvasText;border-radius:10px}',
    ':where(.modal-card.modal-wide){max-width:880px}',
    ':where(.modal-header, .modal-body){padding:16px 20px}',
    ':where(.modal-actions){display:flex;justify-content:flex-end;gap:8px;padding:12px 20px}',
    ':where(.skeleton){height:14px;margin:10px 0;border-radius:4px;background:linear-gradient(90deg,rgba(127,127,127,.12),rgba(127,127,127,.28),rgba(127,127,127,.12));background-size:200% 100%;animation:mv-skeleton 1.2s linear infinite}',
    ':where(.skeleton-title){height:22px;width:40%}',
    ':where(.skeleton-short){width:60%}',
    '@keyframes mv-skeleton{to{background-position:-200% 0}}',
    ':where(.empty){text-align:center;padding:40px 16px}',
    ':where(.app-menu-toggle){display:none;background:none;border:0;font-size:20px;cursor:pointer;color:inherit}',
    '@media (max-width:760px){:where(.app-menu-toggle){display:inline-block}:where(.app-nav){position:fixed;top:0;bottom:0;left:0;z-index:80;background:Canvas;transform:translateX(-100%);transition:transform .2s}:where(.app-shell.nav-open .app-nav){transform:none}:where(.app-role span){display:none}}'
  ].join('\n');

  App.start = function () {
    if (started) return;
    started = true;
    var style = document.createElement('style');
    style.textContent = base;
    document.head.insertBefore(style, document.head.firstChild);
    buildShell();
    window.addEventListener('hashchange', App.refresh);
    document.addEventListener('keydown', function (event) { if (event.key === 'Escape' && modals.length) modals[modals.length - 1](); });
    if (window.DB && DB.on) DB.on(function () { syncShell(); });
    App.refresh();
  };
})();

App.configure({"plan":[{"embedded":false,"hosts":[],"id":"new-research","name":"Новое исследование","route":"\/research\/new"},{"embedded":false,"hosts":[],"id":"research-map","name":"Карта исследования","route":"\/research\/:id"}],"roles":["Исследователь"],"title":"Карта исследования"});
