// UI Studio page runtime, part 3 of 6: stand-ins for blocked SDK scripts (Stripe.js, reCAPTCHA, Google Maps and the analytics SDKs).
(function (A, config) {
  'use strict';
  if (!A.ready) return;   // no configuration, already installed, or no bridge to MarkView (the first part returned early)
  const { realSetTimeout, report, sameServer, surface } = A;
  Object.assign(A, { activateStandIn });

  // The connection policy blocks every script of another origin that the person did not allow (REQ-006), so an SDK loaded from
  // its vendor's CDN never arrives. Stripe.js's loader rejects ("Failed to load Stripe.js"), the page waiting for it does not
  // render, and neither the simulation (fetch, XHR, sockets) nor Fix data has anything to repair. For the SDKs registered below
  // the runtime stands in. A script tag of a registered address that the policy blocks gets its SDK's global as soon as the tag
  // is in the document (a mutation observer runs before the inline script that follows a parsed tag), and when the policy's
  // `error` event arrives the runtime swallows it, calls the callback the address names (`callback=`, `onload=`) and gives
  // the element its `load` event. Nothing leaves the page: no request, no frame. What the SDK would draw is a labelled
  // placeholder, and MarkView lists the SDK as a simulated dependency. An address the person allowed loads for real and is
  // never replaced, even when it fails; an SDK that is not registered stays blocked and is reported as before. Whether the
  // policy blocks an address is decided with the regular expressions the rule list is built from (`allowedFilters`).
  var sdkStandIns = [];
  var sdkInstalled = Object.create(null);
  var sdkAllowed = (config.allowedFilters || []).map(function (filter) {
    try { return new RegExp(filter, 'i'); } catch (error) { return null; }
  }).filter(Boolean);
  // What a payment does in this scenario: an `error` scenario declines the card, any other scenario succeeds.
  var sdkPayment = config.standIns && config.standIns.payment === 'decline' ? 'decline' : 'succeed';
  // Without the connection policy nothing is blocked, so the real SDK loads and there is nothing to stand in for.
  var sdkEnabled = !(config.standIns && config.standIns.enabled === false);
  var SDK_BADGE_PAYMENT = 'Simulated payment — no card is charged';

  function sdkRegister(id, label, matches, install) {
    sdkStandIns.push({ id: id, label: label, matches: matches, install: install });
  }

  function sdkLater(fn, delay) {
    realSetTimeout(function () { try { fn(); } catch (error) { surface(error); } }, delay || 0);
  }

  // A promise that settles a moment later, like a request would.
  function sdkAnswer(value, delay) {
    return new Promise(function (resolve) { realSetTimeout(function () { resolve(value); }, delay === undefined ? 120 : delay); });
  }

  function sdkCall(fn, args) {
    if (typeof fn === 'function') sdkLater(function () { fn.apply(null, args || []); });
  }

  // An object that accepts any call and answers undefined; `known` holds the members that answer something else. A member that
  // would make the object look like a promise or a React element is never invented, so awaiting or rendering one stays harmless.
  var SDK_NOT_INVENTED = { then: 1, toJSON: 1, $$typeof: 1, nodeType: 1, asymmetricMatch: 1 };
  // Calls that register a listener or middleware keep their function, they do not report; every other call that was given a
  // function as its last argument is a reporting call whose completion callback the page waits for.
  var SDK_LISTENS = /^(on|once|off|add|use|subscribe|listen|set_config)/;
  // Analytics SDKs finish a report by calling `hitCallback` (analytics.js), `event_callback` (gtag) or `eventCallback`
  // (Tag Manager) from the object they were given; pages use them for "track, then navigate".
  function sdkDone(value) {
    if (!value || typeof value !== 'object') return;
    ['hitCallback', 'event_callback', 'eventCallback'].forEach(function (name) { sdkCall(value[name]); });
    if (typeof value.length === 'number' && !Array.isArray(value)) Array.prototype.forEach.call(value, function (part) {
      if (part && typeof part === 'object') ['hitCallback', 'event_callback', 'eventCallback'].forEach(function (name) { sdkCall(part[name]); });
    });
  }
  function sdkFinish(args) {
    var list = Array.prototype.slice.call(args);
    if (typeof list[list.length - 1] === 'function') sdkCall(list[list.length - 1]);
    list.forEach(sdkDone);
  }
  // `result` makes what a call answers (analytics-next answers a promise); the default is undefined.
  function sdkQuiet(known, result) {
    return new Proxy(known || {}, {
      get: function (target, key) {
        if (key in target) return target[key];
        if (typeof key !== 'string' || SDK_NOT_INVENTED[key]) return undefined;
        return SDK_LISTENS.test(key) ? function () {} : function () { sdkFinish(arguments); return result ? result() : undefined; };
      }
    });
  }

  function sdkNode(tag, props, children) {
    var node = document.createElement(tag);
    Object.keys(props || {}).forEach(function (key) {
      if (key === 'text') node.textContent = props[key];
      else if (key === 'style') node.style.cssText = props[key];
      else node.setAttribute(key, props[key]);
    });
    (children || []).forEach(function (child) { node.appendChild(child); });
    return node;
  }

  var SDK_STYLE = ':host{display:block;font:13px/1.4 -apple-system,system-ui,sans-serif;color:inherit}'
    + '.box{border:1px dashed #8a8f98;border-radius:8px;padding:10px 12px;background:rgba(127,127,127,.08);box-sizing:border-box;height:100%}'
    + '.badge{display:inline-block;font-size:11px;font-weight:600;padding:1px 6px;border-radius:4px;background:#fde68a;color:#78350f;margin-bottom:6px}'
    + 'label{display:flex;align-items:center;gap:6px;padding:3px 0;cursor:pointer}.note{font-size:12px;opacity:.75;margin-top:6px}';
  // A placeholder in a shadow root, so the page's styles cannot reach it and its own cannot leak out.
  function sdkBox(host, badge, children) {
    var root = host.attachShadow({ mode: 'open' });
    root.appendChild(sdkNode('style', { text: SDK_STYLE }));
    root.appendChild(sdkNode('div', { 'class': 'box' }, [sdkNode('div', { 'class': 'badge', text: badge })].concat(children || [])));
    return root;
  }

  function sdkTarget(target) {
    var node = typeof target === 'string' ? document.querySelector(target) : target;
    if (!node || typeof node.appendChild !== 'function') throw new Error('The selector you specified (' + target + ') applies to no DOM elements that are currently on the page.');
    return node;
  }

  // `callback=initMap` (Google Maps) and `onload=onRecaptcha` (reCAPTCHA) name a function of the page, possibly a dotted path
  // such as `google.maps.__ib__` (Google's inline loader).
  function sdkCallbacks(url) {
    ['callback', 'onload'].forEach(function (name) {
      var path = url.searchParams.get(name);
      if (!path || !/^[A-Za-z_$][\w$]*(\.[A-Za-z_$][\w$]*)*$/.test(path)) return;
      var target = window;
      path.split('.').forEach(function (part) { target = target == null ? undefined : target[part]; });
      if (typeof target === 'function') target();
    });
  }

  // The registered SDK a script address belongs to when the policy blocks it, else null. The SDK's global is defined on the way.
  function sdkStandInFor(address) {
    var url;
    if (!sdkEnabled) return null;
    try { url = new URL(address, location.href); } catch (error) { return null; }
    if (sameServer(url.href) || sdkAllowed.some(function (allowed) { return allowed.test(url.href); })) return null;
    var entry = null;
    for (var i = 0; i < sdkStandIns.length && !entry; i++) if (sdkStandIns[i].matches(url)) entry = sdkStandIns[i];
    if (!entry) return null;
    if (!sdkInstalled[entry.id]) {
      try { entry.install(url); } catch (error) { return null; }
      sdkInstalled[entry.id] = true;
      report('standIn', entry.id + ': ' + entry.label, address);
    }
    return url;
  }

  // The policy blocked `script`: false when the address is not a registered SDK, else the page gets its `load` event.
  function activateStandIn(script, address) {
    var url = sdkStandInFor(address);
    if (!url) return false;
    sdkLater(function () {
      try { sdkCallbacks(url); } catch (error) { surface(error); }
      script.dispatchEvent(new Event('load'));
    });
    return true;
  }

  // A script tag of a registered SDK has its global the moment it is in the document, before the script that follows it runs.
  function sdkScan(node) {
    if (node.nodeType !== 1) return;
    var scripts = node.tagName === 'SCRIPT' ? [node] : node.querySelectorAll ? Array.prototype.slice.call(node.querySelectorAll('script[src]')) : [];
    scripts.forEach(function (script) {
      var address = script.getAttribute('src');
      // A tag with `nomodule` is skipped by every browser that runs this page.
      if (address && !script.hasAttribute('nomodule') && /^(|module|(text|application)\/(x-)?(java|ecma)script)$/i.test((script.getAttribute('type') || '').trim())) sdkStandInFor(address);
    });
  }
  if (typeof MutationObserver === 'function') {
    new MutationObserver(function (records) {
      records.forEach(function (record) { Array.prototype.forEach.call(record.addedNodes, sdkScan); });
    }).observe(document, { childList: true, subtree: true });
  }

  // MARK: Stripe.js stand-in

  var STRIPE_DEFAULT_METHODS = ['card', 'blik', 'p24', 'ideal', 'sepa_debit', 'paypal'];
  var STRIPE_METHOD_LABELS = { card: 'Card', blik: 'BLIK', p24: 'Przelewy24', ideal: 'iDEAL', sepa_debit: 'SEPA Direct Debit', paypal: 'PayPal' };
  // Methods Stripe finishes on another page (a bank, a wallet): the customer comes back to `return_url` afterwards.
  var STRIPE_REDIRECT = /^(ideal|p24|bancontact|sofort|giropay|eps|klarna|affirm|afterpayclearpay|alipay|paypal)$/;
  // stripe.confirm<Name>Payment(clientSecret, data) of the methods that have their own function.
  var STRIPE_PAYMENT_METHODS = ['AcssDebit', 'Affirm', 'AfterpayClearpay', 'Alipay', 'AuBecsDebit', 'BacsDebit', 'Bancontact', 'Blik', 'Boleto',
    'Cashapp', 'Eps', 'Fpx', 'Giropay', 'GrabPay', 'Ideal', 'Klarna', 'Konbini', 'Oxxo', 'P24', 'PayNow', 'PayPal', 'Pix', 'PromptPay',
    'SepaDebit', 'Sofort', 'UsBankAccount', 'WechatPay', 'Zip'];
  var STRIPE_NOT_SIMULATED = ['createSource', 'retrieveSource', 'collectBankAccountForPayment', 'collectBankAccountForSetup',
    'collectBankAccountToken', 'verifyMicrodepositsForPayment', 'verifyMicrodepositsForSetup', 'handleNextAction', 'handleURLAction'];

  function installStripe(url) {
    var counter = 0;
    var confirmed = Object.create(null);   // intent id → the status the stand-in gave it
    var stateOf = new WeakMap();           // an Elements object → { method, secret, options, made }

    function idOf(kind, secret) {
      // pi_123_secret_abc names the intent pi_123
      var match = /^((?:pi|seti)_[A-Za-z0-9]+)_secret_/.exec(String(secret || ''));
      return match ? match[1] : (kind === 'setup' ? 'seti' : 'pi') + '_markview_simulated_' + (++counter);
    }
    function intentOf(kind, id, secret, method, status) {
      return { id: id, object: kind === 'setup' ? 'setup_intent' : 'payment_intent', client_secret: secret || null, status: status,
        livemode: false, created: Math.floor(Date.now() / 1000), payment_method: 'pm_markview_simulated', payment_method_types: [method] };
    }
    function key(kind) { return kind === 'setup' ? 'setupIntent' : 'paymentIntent'; }
    function declined(kind, made) {
      var error = { type: 'card_error', code: 'card_declined', decline_code: 'generic_decline',
        message: 'Your card was declined. (Simulated payment: this scenario simulates a card decline.)' };
      error[kind === 'setup' ? 'setup_intent' : 'payment_intent'] = made;
      return error;
    }

    // What stripe.confirm* does: the scenario decides success or a card decline; a method that leaves the page, or a
    // confirmation that asks for redirect, goes to return_url with the query Stripe adds, and the promise never settles.
    function confirm(kind, secret, method, redirect, returnUrl) {
      var failed = sdkPayment === 'decline';
      var id = idOf(kind, secret);
      var made = intentOf(kind, id, secret, method, failed ? 'requires_payment_method' : 'succeeded');
      confirmed[id] = made.status;
      var leaves = STRIPE_REDIRECT.test(String(method).replace(/_/g, ''));
      if (returnUrl && (leaves || (redirect !== 'if_required' && !failed))) {
        try {
          var target = new URL(returnUrl, location.href);
          // Stripe only returns to a web address; a javascript: or data: address would run script in the page.
          if (target.protocol !== 'http:' && target.protocol !== 'https:') throw new Error('Not a web address');
          target.searchParams.set(kind === 'setup' ? 'setup_intent' : 'payment_intent', id);
          target.searchParams.set(kind === 'setup' ? 'setup_intent_client_secret' : 'payment_intent_client_secret', secret || '');
          target.searchParams.set('redirect_status', failed ? 'failed' : 'succeeded');
          sdkLater(function () { window.location.assign(target.href); }, 120);
          return new Promise(function () {});
        } catch (error) {
          return sdkAnswer({ error: { type: 'invalid_request_error', code: 'parameter_invalid_empty', message: 'The return_url is not a valid URL.' } });
        }
      }
      var result = {};
      if (failed) result.error = declined(kind, made); else result[key(kind)] = made;
      return sdkAnswer(result);
    }

    function retrieve(kind, secret) {
      var id = idOf(kind, secret);
      var query = new URLSearchParams(location.search);
      var status = confirmed[id];
      if (!status) {
        // The page the customer returned to: the redirect says how it went.
        var returned = query.get(kind === 'setup' ? 'setup_intent' : 'payment_intent') === id;
        status = returned && query.get('redirect_status') !== 'failed' ? 'succeeded' : 'requires_payment_method';
      }
      var result = {};
      result[key(kind)] = intentOf(kind, id, secret, 'card', status);
      return sdkAnswer(result, 60);
    }

    function paymentMethod(type) {
      return { id: 'pm_markview_simulated', object: 'payment_method', type: type || 'card', livemode: false,
        card: { brand: 'visa', last4: '4242', exp_month: 12, exp_year: 2034, funding: 'credit', country: 'US' }, billing_details: {} };
    }

    function elementsFor(options) {
      var state = { method: 'card', secret: options && options.clientSecret || null, options: options || {}, made: Object.create(null) };
      var elements = {
        create: function (type, settings) { var made = element(type, settings || {}, state); state.made[type] = made; return made; },
        getElement: function (type) { return state.made[type] || null; },
        update: function (settings) { if (settings && settings.clientSecret) state.secret = settings.clientSecret; },
        fetchUpdates: function () { return sdkAnswer({}, 40); },
        submit: function () { return sdkAnswer({ selectedPaymentMethod: state.method }, 40); }
      };
      stateOf.set(elements, state);
      return elements;
    }

    // An Element: a labelled placeholder that raises the events the page listens to. The payment placeholder offers the
    // payment methods (the page's own `paymentMethodTypes`, or the usual ones) and reports the one chosen as `value.type`.
    function element(type, settings, state) {
      var handlers = Object.create(null);
      var host = null;
      var detail = null;
      function emit(name, payload) {
        (handlers[name] || []).slice().forEach(function (fn) { try { fn(payload || {}); } catch (error) { surface(error); } });
      }
      // What the Link authentication and Address Elements hand to the page in `value`.
      function filled() {
        if (type === 'linkAuthentication') return { email: 'test@example.com' };
        if (type === 'address') {
          return { name: 'Test Customer', firstName: 'Test', lastName: 'Customer',
            address: { line1: '1 Test Street', line2: null, city: 'Test City', state: 'CA', postal_code: '94000', country: 'US' } };
        }
        return undefined;
      }
      function changed() {
        var event = { elementType: type, empty: false, complete: true, collapsed: false };
        if (type === 'payment') event.value = { type: state.method };
        else if (/^card/.test(type)) event.brand = 'visa';
        else if (filled()) event.value = filled();
        emit('change', event);
      }
      function describe(method) {
        return method === 'card' ? 'Test card 4242 4242 4242 4242 · 12/34 · 123'
          : STRIPE_REDIRECT.test(method.replace(/_/g, '')) ? 'A simulated bank page opens after you pay.' : 'Confirmed with a simulated code.';
      }
      function build(node) {
        var children = [];
        if (type === 'payment') {
          var methods = (settings.paymentMethodTypes || state.options.paymentMethodTypes || STRIPE_DEFAULT_METHODS).filter(function (m) { return typeof m === 'string'; });
          if (methods.indexOf(state.method) < 0) state.method = methods[0] || 'card';
          detail = sdkNode('div', { 'class': 'note', text: describe(state.method) });
          methods.forEach(function (method) {
            var radio = sdkNode('input', { type: 'radio', name: 'method', value: method });
            if (method === state.method) radio.checked = true;
            radio.addEventListener('change', function () { state.method = method; detail.textContent = describe(method); changed(); });
            children.push(sdkNode('label', {}, [radio, sdkNode('span', { text: STRIPE_METHOD_LABELS[method] || method })]));
          });
          children.push(detail);
        } else if (/^card/.test(type)) {
          children.push(sdkNode('div', { text: 'Test card 4242 4242 4242 4242 · 12/34 · 123' }));
        } else {
          children.push(sdkNode('div', { text: 'Simulated ' + type + ' element' }));
        }
        sdkBox(node, SDK_BADGE_PAYMENT, children);
      }
      var self = {
        mount: function (target) {
          var node = sdkTarget(target);
          self.unmount();
          host = sdkNode('div', { 'data-markview-standin': 'stripe-' + type });
          build(host);
          node.appendChild(host);
          sdkLater(function () { emit('loaderstart', { elementType: type }); }, 20);
          sdkLater(function () { emit('ready', { elementType: type }); changed(); }, 60);
          return self;
        },
        unmount: function () { if (host && host.parentNode) host.parentNode.removeChild(host); host = null; },
        destroy: function () { self.unmount(); handlers = Object.create(null); },
        update: function (next) { if (next) settings = Object.assign({}, settings, next); return self; },
        on: function (name, fn) { (handlers[name] = handlers[name] || []).push(fn); return self; },
        once: function (name, fn) { var once = function (payload) { self.off(name, once); fn(payload); }; return self.on(name, once); },
        off: function (name, fn) { handlers[name] = fn ? (handlers[name] || []).filter(function (h) { return h !== fn; }) : []; return self; },
        focus: function () { var first = host && host.shadowRoot && host.shadowRoot.querySelector('input'); if (first) first.focus(); },
        blur: function () {}, clear: function () {}, collapse: function () {}
      };
      if (type === 'address') self.getValue = function () { return sdkAnswer({ complete: true, isNewAddress: true, value: filled() }, 20); };
      return self;
    }

    function stripeFor() {
      var stripe = {
        elements: elementsFor,
        confirmPayment: function (args) {
          args = args || {};
          var state = args.elements && stateOf.get(args.elements) || {};
          return confirm('payment', args.clientSecret || state.secret, state.method || 'card', args.redirect, (args.confirmParams || {}).return_url);
        },
        confirmSetup: function (args) {
          args = args || {};
          var state = args.elements && stateOf.get(args.elements) || {};
          return confirm('setup', args.clientSecret || state.secret, state.method || 'card', args.redirect, (args.confirmParams || {}).return_url);
        },
        confirmCardPayment: function (secret) { return confirm('payment', secret, 'card', 'if_required', null); },
        confirmCardSetup: function (secret) { return confirm('setup', secret, 'card', 'if_required', null); },
        handleCardAction: function (secret) { return confirm('payment', secret, 'card', 'if_required', null); },
        retrievePaymentIntent: function (secret) { return retrieve('payment', secret); },
        retrieveSetupIntent: function (secret) { return retrieve('setup', secret); },
        createPaymentMethod: function (args) {
          args = args || {};
          var state = args.elements && stateOf.get(args.elements) || {};
          return sdkAnswer({ paymentMethod: paymentMethod(args.type || state.method) }, 60);
        },
        createToken: function () {
          return sdkAnswer({ token: { id: 'tok_markview_simulated', object: 'token', type: 'card', livemode: false, used: false, card: paymentMethod('card').card } }, 60);
        },
        createConfirmationToken: function (args) {
          var state = args && args.elements && stateOf.get(args.elements) || {};
          return sdkAnswer({ confirmationToken: { id: 'ctoken_markview_simulated', object: 'confirmation_token', livemode: false,
            payment_method_preview: { type: state.method || 'card' } } }, 60);
        },
        // No wallet is offered.
        paymentRequest: function () {
          return { canMakePayment: function () { return sdkAnswer(null, 20); }, on: function () {}, off: function () {}, show: function () {},
            update: function () {}, abort: function () {}, isShowing: function () { return false; } };
        },
        redirectToCheckout: function (options) {
          var session = options && options.sessionId ? String(options.sessionId) : 'markview_simulated';
          sdkLater(function () { window.location.assign('https://checkout.stripe.com/c/pay/' + encodeURIComponent(session)); }, 120);
          return new Promise(function () {});
        },
        initEmbeddedCheckout: function () {
          var host = null;
          var checkout = {
            mount: function (target) {
              var node = sdkTarget(target);
              checkout.unmount();
              host = sdkNode('div', { 'data-markview-standin': 'stripe-embedded-checkout' });
              sdkBox(host, SDK_BADGE_PAYMENT, [sdkNode('div', { text: 'Simulated Stripe Checkout' })]);
              node.appendChild(host);
            },
            unmount: function () { if (host && host.parentNode) host.parentNode.removeChild(host); host = null; },
            destroy: function () { checkout.unmount(); }
          };
          return sdkAnswer(checkout, 60);
        },
        registerAppInfo: function () {},
        _registerWrapper: function () {}
      };
      STRIPE_PAYMENT_METHODS.forEach(function (name) {
        stripe['confirm' + name + 'Payment'] = function (secret, data) {
          return confirm('payment', secret, name.toLowerCase(), 'if_required', data && data.return_url);
        };
      });
      STRIPE_NOT_SIMULATED.forEach(function (name) {
        stripe[name] = function () {
          report('unsupported', 'stripe.' + name + '() is not simulated by UI Studio.');
          return sdkAnswer({ error: { type: 'invalid_request_error', code: 'markview_not_simulated', message: 'UI Studio does not simulate stripe.' + name + '().' } });
        };
      });
      return stripe;
    }

    var Stripe = function Stripe() { return stripeFor(); };
    // Stripe.js@v3 reports 3; the release trains (js.stripe.com/basil/stripe.js) report their name. @stripe/stripe-js warns when
    // the loaded version is not the one it expects.
    Stripe.version = /^\/v3(\/|$)/.test(url.pathname) ? 3 : (url.pathname.split('/')[1] || 3);
    if (window.Stripe === undefined) window.Stripe = Stripe;
  }

  // MARK: reCAPTCHA stand-in

  var RECAPTCHA_TOKEN = 'markview-simulated-recaptcha-token';
  function installRecaptcha(url) {
    var widgets = [];
    // A checkbox widget is solved the moment it is drawn. An invisible one (size: 'invisible') calls its callback only when the
    // page asks for the challenge: grecaptcha.execute(), or a click on the button that carries the widget.
    function invisible(params) { return String(params.size || '').toLowerCase() === 'invisible'; }
    function solve(widget) { sdkCall(widget.callback, [RECAPTCHA_TOKEN]); }
    function render(container, params) {
      params = params || {};
      var id = widgets.length;
      widgets.push(params);
      var node = typeof container === 'string' ? document.getElementById(container) || document.querySelector(container) : container;
      if (invisible(params)) {
        if (node && (node.tagName === 'BUTTON' || node.tagName === 'INPUT')) {
          node.addEventListener('click', function (event) { event.preventDefault(); solve(params); });
        }
        return id;
      }
      if (node) {
        var host = sdkNode('div', { 'data-markview-standin': 'recaptcha' });
        sdkBox(host, 'Simulated reCAPTCHA', [sdkNode('div', { text: '☑ I’m not a robot — solved automatically' })]);
        node.appendChild(host);
      }
      solve(params);
      return id;
    }
    var api = {
      ready: function (fn) { sdkCall(fn); },
      // v3: execute(siteKey, { action }) answers a token; v2 invisible: execute(widgetId) calls the widget's callback, and
      // execute() without an id is the first widget.
      execute: function (first) {
        var widget = typeof first === 'number' ? widgets[first] : first === undefined ? widgets[0] : null;
        if (widget) solve(widget);
        return sdkAnswer(RECAPTCHA_TOKEN, 60);
      },
      render: render,
      getResponse: function () { return RECAPTCHA_TOKEN; },
      reset: function () {}
    };
    api.enterprise = api;
    var target = window.grecaptcha || (window.grecaptcha = {});
    Object.keys(api).forEach(function (name) { target[name] = api[name]; });
    // Callbacks queued by the page's inline snippet before the API arrived.
    var queued = window.___grecaptcha_cfg && window.___grecaptcha_cfg.fns;
    if (Array.isArray(queued)) queued.splice(0).forEach(function (fn) { sdkCall(fn); });
    // The API draws every <div class="g-recaptcha"> of the document once it is parsed, unless the page renders explicitly.
    if (url.searchParams.get('render') === 'explicit') return;
    function drawAll() {
      Array.prototype.slice.call(document.querySelectorAll('.g-recaptcha')).forEach(function (node) {
        var name = node.getAttribute('data-callback');
        render(node, { callback: name && typeof window[name] === 'function' ? window[name] : undefined, size: node.getAttribute('data-size') || undefined });
      });
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', function () { sdkLater(drawAll); });
    else sdkLater(drawAll);
  }

  // MARK: Google Maps stand-in

  // The map is a labelled placeholder; markers, info windows, shapes and services accept their calls and keep what the page set
  // on them, geocoding and place searches find nothing, and the events pages wait for (`idle`, `tilesloaded`) are raised.
  function installMaps() {
    var google = window.google || (window.google = {});
    // The namespace is filled in place: Google's inline loader keeps a reference to the object it created.
    var maps = google.maps || (google.maps = {});
    var listeners = new WeakMap();
    var values = new WeakMap();
    // The state of an object is made when it is first used: an instance built the classic way, as
    // `Sub.prototype = new google.maps.OverlayView()`, never ran the constructor for itself.
    function valuesOf(object) {
      var state = values.get(object);
      if (!state) { state = {}; values.set(object, state); }
      return state;
    }

    function listen(target, name, fn, once) {
      var all = listeners.get(target);
      if (!all) { all = Object.create(null); listeners.set(target, all); }
      var entry = { fn: fn, once: !!once };
      (all[name] = all[name] || []).push(entry);
      return { remove: function () { var list = all[name] || []; var at = list.indexOf(entry); if (at >= 0) list.splice(at, 1); } };
    }
    function trigger(target, name, args) {
      var all = listeners.get(target);
      var list = all && all[name];
      (list || []).slice().forEach(function (entry) {
        if (entry.once) { var at = list.indexOf(entry); if (at >= 0) list.splice(at, 1); }
        try { entry.fn.apply(target, args || []); } catch (error) { surface(error); }
      });
    }
    maps.event = {
      addListener: function (target, name, fn) { return listen(target, name, fn); },
      addListenerOnce: function (target, name, fn) { return listen(target, name, fn, true); },
      addDomListener: function (node, name, fn) { node.addEventListener(name, fn); return { remove: function () { node.removeEventListener(name, fn); } }; },
      removeListener: function (listener) { if (listener && listener.remove) listener.remove(); },
      clearListeners: function (target, name) { var all = listeners.get(target); if (all) all[name] = []; },
      clearInstanceListeners: function (target) { listeners.delete(target); },
      trigger: function (target, name) { trigger(target, name, Array.prototype.slice.call(arguments, 2)); }
    };

    function MVCObject() { valuesOf(this); }
    MVCObject.prototype.addListener = function (name, fn) { return listen(this, name, fn); };
    MVCObject.prototype.get = function (name) { return valuesOf(this)[name]; };
    MVCObject.prototype.set = function (name, value) { valuesOf(this)[name] = value; };
    MVCObject.prototype.setValues = function (next) { Object.assign(valuesOf(this), next); };
    MVCObject.prototype.notify = function () {};
    MVCObject.prototype.bindTo = function () {};
    MVCObject.prototype.unbind = function () {};
    maps.MVCObject = MVCObject;

    // A class whose instances keep options and offer get<Name>/set<Name> for the names given.
    // A position or a center is read back as a LatLng, whether the page gave a LatLng or a {lat, lng} literal.
    function keep(state, field, value) { state[field] = (field === 'position' || field === 'center') && value ? toLatLng(value) : value; }
    function shape(names, extra) {
      function Shape(options) {
        MVCObject.call(this);
        var state = valuesOf(this);
        Object.keys(options || {}).forEach(function (field) { keep(state, field, options[field]); });
      }
      Shape.prototype = Object.create(MVCObject.prototype);
      Shape.prototype.constructor = Shape;
      Shape.prototype.setOptions = function (next) {
        var state = valuesOf(this);
        Object.keys(next || {}).forEach(function (field) { keep(state, field, next[field]); });
      };
      names.forEach(function (name) {
        var field = name.charAt(0).toLowerCase() + name.slice(1);
        Shape.prototype['get' + name] = function () { return valuesOf(this)[field]; };
        Shape.prototype['set' + name] = function (value) { keep(valuesOf(this), field, value); };
      });
      Object.keys((extra && extra.methods) || {}).forEach(function (name) { Shape.prototype[name] = extra.methods[name]; });
      return Shape;
    }

    function LatLng(lat, lng) {
      if (lat && typeof lat === 'object') { lng = lat.lng; lat = lat.lat; }
      this._lat = Number(lat) || 0; this._lng = Number(lng) || 0;
    }
    LatLng.prototype.lat = function () { return this._lat; };
    LatLng.prototype.lng = function () { return this._lng; };
    LatLng.prototype.equals = function (other) { return !!other && other.lat() === this._lat && other.lng() === this._lng; };
    LatLng.prototype.toJSON = function () { return { lat: this._lat, lng: this._lng }; };
    LatLng.prototype.toString = function () { return '(' + this._lat + ', ' + this._lng + ')'; };
    LatLng.prototype.toUrlValue = function () { return this._lat + ',' + this._lng; };
    function toLatLng(value) { return value instanceof LatLng ? value : new LatLng(value); }

    function LatLngBounds(sw, ne) {
      this._points = [];
      if (sw) this.extend(sw);
      if (ne) this.extend(ne);
    }
    LatLngBounds.prototype.extend = function (point) { this._points.push(toLatLng(point)); return this; };
    LatLngBounds.prototype.isEmpty = function () { return this._points.length === 0; };
    function span(bounds, axis) {
      var all = bounds._points.map(function (p) { return p[axis](); });
      return all.length ? [Math.min.apply(null, all), Math.max.apply(null, all)] : [0, 0];
    }
    LatLngBounds.prototype.getSouthWest = function () { return new LatLng(span(this, 'lat')[0], span(this, 'lng')[0]); };
    LatLngBounds.prototype.getNorthEast = function () { return new LatLng(span(this, 'lat')[1], span(this, 'lng')[1]); };
    LatLngBounds.prototype.getCenter = function () {
      var lat = span(this, 'lat'), lng = span(this, 'lng');
      return new LatLng((lat[0] + lat[1]) / 2, (lng[0] + lng[1]) / 2);
    };
    LatLngBounds.prototype.contains = function (point) {
      var p = toLatLng(point), lat = span(this, 'lat'), lng = span(this, 'lng');
      return p.lat() >= lat[0] && p.lat() <= lat[1] && p.lng() >= lng[0] && p.lng() <= lng[1];
    };
    LatLngBounds.prototype.union = function (other) { var self = this; if (other) other._points.forEach(function (p) { self.extend(p); }); return this; };
    LatLngBounds.prototype.toJSON = function () {
      var sw = this.getSouthWest(), ne = this.getNorthEast();
      return { south: sw.lat(), west: sw.lng(), north: ne.lat(), east: ne.lng() };
    };

    function Point(x, y) { this.x = x; this.y = y; }
    function Size(width, height) { this.width = width; this.height = height; }

    function GoogleMap(node, options) {
      MVCObject.call(this);
      var state = valuesOf(this);
      Object.assign(state, options || {});
      state.center = toLatLng(state.center || { lat: 0, lng: 0 });
      state.zoom = state.zoom === undefined ? 8 : state.zoom;
      state.mapTypeId = state.mapTypeId || 'roadmap';
      this.controls = []; this.data = sdkQuiet(); this.mapTypes = sdkQuiet(); this.overlayMapTypes = sdkQuiet();
      var self = this;
      var label = sdkNode('div', {});
      var host = sdkNode('div', { 'data-markview-standin': 'google-maps', style: 'display:block;width:100%;height:100%;min-height:120px' });
      sdkBox(host, 'Simulated map', [label]);
      node.appendChild(host);
      this._label = label;
      this._div = node;
      this._draw();
      sdkLater(function () { trigger(self, 'tilesloaded'); trigger(self, 'idle'); }, 30);
    }
    GoogleMap.prototype = Object.create(MVCObject.prototype);
    GoogleMap.prototype.constructor = GoogleMap;
    GoogleMap.prototype._draw = function () {
      var state = valuesOf(this);
      this._label.textContent = state.center.lat().toFixed(4) + ', ' + state.center.lng().toFixed(4) + ' · zoom ' + state.zoom;
    };
    GoogleMap.prototype._changed = function () { var self = this; this._draw(); sdkLater(function () { trigger(self, 'idle'); }, 30); };
    GoogleMap.prototype.getDiv = function () { return this._div; };
    GoogleMap.prototype.getCenter = function () { return valuesOf(this).center; };
    GoogleMap.prototype.setCenter = function (point) { valuesOf(this).center = toLatLng(point); this._changed(); };
    GoogleMap.prototype.panTo = GoogleMap.prototype.setCenter;
    GoogleMap.prototype.panBy = function () {};
    GoogleMap.prototype.getZoom = function () { return valuesOf(this).zoom; };
    GoogleMap.prototype.setZoom = function (zoom) { valuesOf(this).zoom = zoom; this._changed(); };
    GoogleMap.prototype.getMapTypeId = function () { return valuesOf(this).mapTypeId; };
    GoogleMap.prototype.setMapTypeId = function (id) { valuesOf(this).mapTypeId = id; };
    GoogleMap.prototype.setOptions = function (next) {
      var state = valuesOf(this);
      Object.assign(state, next || {});
      if (next && next.center) state.center = toLatLng(next.center);
      this._changed();
    };
    GoogleMap.prototype.fitBounds = function (bounds) { if (bounds && !bounds.isEmpty()) valuesOf(this).center = bounds.getCenter(); this._changed(); };
    GoogleMap.prototype.getBounds = function () { var c = valuesOf(this).center; return new LatLngBounds(c, c); };
    GoogleMap.prototype.getProjection = function () { return undefined; };
    GoogleMap.prototype.getClickableIcons = function () { return true; };

    var Marker = shape(['Map', 'Position', 'Title', 'Label', 'Icon', 'Visible', 'Draggable', 'Opacity', 'ZIndex', 'Animation', 'Clickable', 'Cursor', 'Shape']);
    // The marker element of the newer API keeps its options as properties.
    function AdvancedMarkerElement(options) { Object.assign(this, options || {}); }
    AdvancedMarkerElement.prototype.addListener = function (name, fn) { return listen(this, name, fn); };
    AdvancedMarkerElement.prototype.addEventListener = function (name, fn) { return listen(this, name, fn); };
    AdvancedMarkerElement.prototype.remove = function () { this.map = null; };
    function PinElement(options) { Object.assign(this, options || {}); this.element = document.createElement('div'); }

    var InfoWindow = shape(['Content', 'Position', 'ZIndex'], {
      methods: {
        open: function (map) { var state = valuesOf(this); state.map = map && map.map ? map.map : map; trigger(this, 'domready'); },
        close: function () { valuesOf(this).map = null; trigger(this, 'closeclick'); }
      }
    });

    var Overlay = shape(['Map', 'Path', 'Paths', 'Center', 'Radius', 'Bounds', 'Visible', 'Editable', 'Draggable'], {
      methods: { getPanes: function () { return null; }, getProjection: function () { return null; } }
    });
    var overlayShapes = ['Polyline', 'Polygon', 'Circle', 'Rectangle', 'GroundOverlay', 'TrafficLayer', 'TransitLayer', 'BicyclingLayer', 'KmlLayer'];
    overlayShapes.forEach(function (name) { maps[name] = shape(['Map', 'Path', 'Paths', 'Center', 'Radius', 'Bounds', 'Visible', 'Editable', 'Draggable']); });

    // Geocoding answers one simulated address, place searches find nothing, in the callback form and the promise form.
    function component(long, short, types) { return { long_name: long, short_name: short, types: types }; }
    function Geocoder() {}
    Geocoder.prototype.geocode = function (request, callback) {
      var found = [{ formatted_address: request && request.address || '1 Test Street, Test City, CA 94000, USA', place_id: 'markview-simulated-place',
        types: ['street_address'],
        address_components: [component('1', '1', ['street_number']), component('Test Street', 'Test St', ['route']),
          component('Test City', 'Test City', ['locality', 'political']), component('California', 'CA', ['administrative_area_level_1', 'political']),
          component('United States', 'US', ['country', 'political']), component('94000', '94000', ['postal_code'])],
        geometry: { location: new LatLng(0, 0), viewport: new LatLngBounds(new LatLng(0, 0), new LatLng(0, 0)) } }];
      sdkCall(callback, [found, 'OK']);
      return sdkAnswer({ results: found }, 60);
    };
    function emptyService(promised) {
      return function (request, callback) {
        sdkCall(callback, promised === 'predictions' ? [[], 'ZERO_RESULTS'] : [[], 'ZERO_RESULTS', null]);
        var result = {}; result[promised] = [];
        return sdkAnswer(result, 60);
      };
    }
    function PlacesService() {}
    ['findPlaceFromQuery', 'findPlaceFromPhoneNumber', 'nearbySearch', 'textSearch'].forEach(function (name) { PlacesService.prototype[name] = emptyService('results'); });
    PlacesService.prototype.getDetails = function (request, callback) {
      sdkCall(callback, [{ name: 'Simulated place', formatted_address: 'Simulated address', place_id: request && request.placeId || 'markview-simulated-place',
        geometry: { location: new LatLng(0, 0) } }, 'OK']);
    };
    function AutocompleteService() {}
    AutocompleteService.prototype.getPlacePredictions = emptyService('predictions');
    AutocompleteService.prototype.getQueryPredictions = emptyService('predictions');
    // The input offers no suggestions; what was typed is the place once the field changes.
    function Autocomplete(input, options) {
      MVCObject.call(this);
      var self = this;
      this._input = input;
      Object.assign(valuesOf(this), options || {});
      if (input && input.addEventListener) input.addEventListener('change', function () { trigger(self, 'place_changed'); });
    }
    Autocomplete.prototype = Object.create(MVCObject.prototype);
    Autocomplete.prototype.constructor = Autocomplete;
    Autocomplete.prototype.getPlace = function () {
      var typed = this._input && this._input.value || '';
      return { name: typed || 'Simulated place', formatted_address: typed || 'Simulated address', place_id: 'markview-simulated-place',
        geometry: { location: new LatLng(0, 0) }, address_components: [] };
    };
    ['setBounds', 'setComponentRestrictions', 'setFields', 'setOptions', 'setTypes', 'bindTo'].forEach(function (name) { Autocomplete.prototype[name] = function () {}; });
    Autocomplete.prototype.getBounds = function () { return undefined; };
    function Place(options) { Object.assign(this, options || {}); }
    Place.prototype.fetchFields = function () { return sdkAnswer({ place: this }, 60); };
    Place.searchByText = function () { return sdkAnswer({ places: [] }, 60); };
    Place.searchNearby = Place.searchByText;

    function DirectionsService() {}
    DirectionsService.prototype.route = function (request, callback) {
      if (typeof callback === 'function') { sdkCall(callback, [null, 'ZERO_RESULTS']); return sdkAnswer({ routes: [] }, 60); }
      return Promise.reject(Object.assign(new Error('DIRECTIONS_ROUTE: ZERO_RESULTS (simulated)'), { code: 'ZERO_RESULTS' }));
    };
    function haversine(a, b) {
      var rad = Math.PI / 180, p = toLatLng(a), q = toLatLng(b);
      var dLat = (q.lat() - p.lat()) * rad, dLng = (q.lng() - p.lng()) * rad;
      var h = Math.pow(Math.sin(dLat / 2), 2) + Math.cos(p.lat() * rad) * Math.cos(q.lat() * rad) * Math.pow(Math.sin(dLng / 2), 2);
      return 2 * 6378137 * Math.asin(Math.sqrt(h));
    }

    Object.assign(maps, {
      version: '3.simulated', LatLng: LatLng, LatLngBounds: LatLngBounds, Point: Point, Size: Size, Map: GoogleMap, Marker: Marker,
      InfoWindow: InfoWindow, OverlayView: Overlay, Geocoder: Geocoder, DirectionsService: DirectionsService,
      DirectionsRenderer: shape(['Map', 'Directions']), StreetViewPanorama: shape(['Position', 'Pov', 'Visible']),
      DistanceMatrixService: function () { this.getDistanceMatrix = function (request, callback) { sdkCall(callback, [{ rows: [] }, 'ZERO_RESULTS']); return sdkAnswer({ rows: [] }, 60); }; },
      MapTypeId: { ROADMAP: 'roadmap', SATELLITE: 'satellite', HYBRID: 'hybrid', TERRAIN: 'terrain' },
      ControlPosition: { TOP_LEFT: 1, TOP_CENTER: 2, TOP_RIGHT: 3, LEFT_CENTER: 4, RIGHT_CENTER: 5, BOTTOM_LEFT: 6, BOTTOM_CENTER: 7, BOTTOM_RIGHT: 8 },
      Animation: { BOUNCE: 1, DROP: 2 }, SymbolPath: { CIRCLE: 0, FORWARD_CLOSED_ARROW: 1, FORWARD_OPEN_ARROW: 2, BACKWARD_CLOSED_ARROW: 3, BACKWARD_OPEN_ARROW: 4 },
      GeocoderStatus: { OK: 'OK', ZERO_RESULTS: 'ZERO_RESULTS' }, MapTypeControlStyle: { DEFAULT: 0, HORIZONTAL_BAR: 1, DROPDOWN_MENU: 2 },
      DirectionsStatus: { OK: 'OK', NOT_FOUND: 'NOT_FOUND', ZERO_RESULTS: 'ZERO_RESULTS', INVALID_REQUEST: 'INVALID_REQUEST' },
      UnitSystem: { METRIC: 0, IMPERIAL: 1 }, TravelMode: { DRIVING: 'DRIVING', WALKING: 'WALKING', BICYCLING: 'BICYCLING', TRANSIT: 'TRANSIT' },
      places: { Autocomplete: Autocomplete, AutocompleteService: AutocompleteService, PlacesService: PlacesService, Place: Place,
        AutocompleteSessionToken: function () {}, PlacesServiceStatus: { OK: 'OK', ZERO_RESULTS: 'ZERO_RESULTS' } },
      marker: { AdvancedMarkerElement: AdvancedMarkerElement, PinElement: PinElement, Marker: Marker },
      geometry: { spherical: { computeDistanceBetween: haversine }, encoding: { decodePath: function () { return []; }, encodePath: function () { return ''; } },
        poly: { containsLocation: function () { return false; } } },
      visualization: { HeatmapLayer: shape(['Map', 'Data']) }
    });

    // google.maps.importLibrary('places') and the others: every library comes from the same namespace. A class that is not
    // simulated is a harmless shape, reported once, so the page can go on.
    maps.importLibrary = function () {
      var merged = Object.assign({}, maps, maps.places, maps.marker, maps.geometry, maps.visualization);
      return Promise.resolve(new Proxy(merged, {
        get: function (target, name) {
          if (name in target) return target[name];
          if (typeof name === 'string' && /^[A-Z]/.test(name)) {
            report('unsupported', 'google.maps.' + name + ' is not simulated; it accepts calls and does nothing.');
            target[name] = shape([]);
            return target[name];
          }
          return undefined;
        }
      }));
    };
  }

  // MARK: Analytics stand-ins

  // Analytics SDKs only report. Their globals accept every call, nothing is sent, and the callbacks pages wait for (`ready`,
  // feature flags, Google's `ga(function () {})`) run.
  // gtag.js and Tag Manager: `dataLayer`, `gtag` and the callbacks of the events pushed to it.
  function installGoogleTag() {
    window.dataLayer = window.dataLayer || [];
    // Tag Manager and gtag.js call `eventCallback` / `event_callback` once an event is handled.
    if (!window.dataLayer.__markview) {
      var push = window.dataLayer.push;
      Object.defineProperty(window.dataLayer, '__markview', { value: true });
      window.dataLayer.push = function () {
        var result = push.apply(this, arguments);
        Array.prototype.forEach.call(arguments, sdkDone);
        return result;
      };
      window.dataLayer.forEach(sdkDone);
    }
    if (typeof window.gtag !== 'function') window.gtag = function () { window.dataLayer.push(arguments); };
    window.google_tag_manager = window.google_tag_manager || {};
  }
  // The classic analytics.js (and ga.js): the `ga` command queue.
  function installGoogleAnalytics() {
    var queued = window.ga && window.ga.q;
    var tracker = sdkQuiet();
    var ga = function (first) {
      if (typeof first === 'function') sdkCall(first, [tracker]);
      else sdkFinish(arguments);
    };
    ga.loaded = true;
    ga.create = function () { return tracker; };
    ga.getAll = function () { return [tracker]; };
    ga.getByName = function () { return tracker; };
    window.ga = ga;
    window.GoogleAnalyticsObject = 'ga';
    if (Array.isArray(queued)) queued.forEach(function (args) { ga.apply(null, args); });
  }
  function installSegment() {
    if (window.analytics && !Array.isArray(window.analytics)) return;
    var user = sdkQuiet({ id: function () { return null; }, anonymousId: function () { return 'markview-simulated'; }, traits: function () { return {}; } });
    // analytics-next answers a promise from track(), identify() and the others.
    window.analytics = sdkQuiet({ initialized: true, ready: function (fn) { sdkCall(fn); }, user: function () { return user; } },
      function () { return Promise.resolve({}); });
  }
  function installMixpanel() {
    if (window.mixpanel && !Array.isArray(window.mixpanel)) return;
    window.mixpanel = sdkQuiet({ __loaded: true, get_distinct_id: function () { return 'markview-simulated'; }, init: function () {},
      people: sdkQuiet(), loaded: true });
  }
  function installPostHog() {
    if (window.posthog && !Array.isArray(window.posthog)) return;
    window.posthog = sdkQuiet({ __loaded: true, onFeatureFlags: function (fn) { sdkCall(fn, [[], {}]); }, isFeatureEnabled: function () { return false; },
      getFeatureFlag: function () { return undefined; }, get_distinct_id: function () { return 'markview-simulated'; }, init: function () {} });
  }
  function installPlausible() {
    if (typeof window.plausible !== 'function') window.plausible = function () {};
  }

  function sdkAt(url, hosts, path) { return hosts.indexOf(url.hostname) >= 0 && path.test(url.pathname); }
  sdkRegister('stripe', 'Stripe.js — payments are simulated, no card is charged',
    function (url) { return url.hostname === 'js.stripe.com' && /^\/(v3|[a-z0-9]+\/stripe\.js)\/?$/.test(url.pathname); }, installStripe);
  sdkRegister('recaptcha', 'reCAPTCHA — solved automatically, no token is verified',
    function (url) { return sdkAt(url, ['www.google.com', 'www.recaptcha.net'], /^\/recaptcha\/(api|enterprise)\.js$/); }, installRecaptcha);
  sdkRegister('google-maps', 'Google Maps — a placeholder map, no tiles; geocoding answers one simulated address, places find nothing',
    function (url) { return sdkAt(url, ['maps.googleapis.com', 'maps.google.com'], /^\/maps\/api\/js\/?$/); }, installMaps);
  sdkRegister('google-tag', 'Google Tag Manager and gtag.js — nothing is sent',
    function (url) { return sdkAt(url, ['www.googletagmanager.com'], /^\/(gtag\/js|gtm\.js)$/); }, installGoogleTag);
  sdkRegister('google-analytics', 'Google Analytics (analytics.js) — nothing is sent',
    function (url) { return sdkAt(url, ['www.google-analytics.com', 'ssl.google-analytics.com'], /^\/(analytics|ga)\.js$/); }, installGoogleAnalytics);
  sdkRegister('segment', 'Segment — nothing is sent',
    function (url) { return sdkAt(url, ['cdn.segment.com'], /^\/(analytics\.js|analytics-next)\//); }, installSegment);
  sdkRegister('mixpanel', 'Mixpanel — nothing is sent',
    function (url) { return sdkAt(url, ['cdn.mxpnl.com', 'cdn.mixpanel.com'], /^\/libs\/mixpanel[\w.-]*\.js$/); }, installMixpanel);
  sdkRegister('posthog', 'PostHog — nothing is sent, no feature flag is on',
    function (url) { return /(^|\.)posthog\.com$/.test(url.hostname) && /^\/static\/[\w.-]+\.js$/.test(url.pathname); }, installPostHog);
  sdkRegister('plausible', 'Plausible — nothing is sent',
    function (url) { return sdkAt(url, ['plausible.io'], /^\/js\/[\w.-]+\.js$/); }, installPlausible);

  // MARK: Errors, build overlays, blocked resources, routes
})(window.__markviewStudioParts, __MARKVIEW_STUDIO_CONFIG__);
