// MarkView UI Studio page runtime. Injected at document start into the page world of a UI Studio session, before the
// application's own scripts, with the session's configuration in place of the placeholder at the end of this file.
//
// What it does in the page:
// - Every fetch and XMLHttpRequest is asked of MarkView first (`markviewStudio` message handler with reply). MarkView
//   answers from the simulated environment or lets a local or explicitly allowed request through; nothing falls through
//   to a real service on its own (REQ-002, REQ-006).
// - WebSocket and EventSource talk to MarkView's simulated channels (REQ-015): open, messages and close travel over the
//   bridge, and MarkView pushes its own messages with `deliver`. The dev server's own sockets (hot reload, and anything on
//   its origin that is not a known API path) stay real. sendBeacon is reported as unsupported and not sent.
// - Math.random is seeded, the clock starts at the scenario's test time, and the locale (and the time zone of formatted
//   dates) follow the scenario, so captures are reproducible.
// - Location, permissions, the clipboard, camera and microphone, and notifications answer from the scenario's browser
//   settings, never from the Mac; the localStorage entries the person kept are written once per generation (REQ-008).
// - An Electron renderer's preload bridge (the globals its preload exposes) is simulated like any other API (REQ-016): a
//   call is a request to the logical address `http://electron.ipc/<global>/<path>`, a callback listens to the simulated
//   channel there.
// - An SDK script of another origin that the connection policy blocks (Stripe.js, reCAPTCHA, Google Maps, analytics) gets a
//   stand-in: its global is defined, nothing leaves the page, what it draws is labelled as simulated, and a payment succeeds
//   or is declined as the scenario says (BUG-103).
// - Uncaught errors, the dev server's build error overlay, blocked resources, route changes, synchronous IPC and "the page
//   is idle" are reported.
// - Select mode: hover highlights, a click selects without running the element's action, parent navigation; the selection
//   carries what the framework's development metadata says about its source and its repeated instances.
// - Restoration steps are recorded and replayed; a capture freezes animations and hides the overlay.
//
// The API for MarkView is `window.__markviewStudio`. The project is trusted local code (REQ-006): this runtime is a
// test harness in the page, not a security boundary, and every message it sends is validated again natively.

// UI Studio page runtime, part 1 of 6: the bridge to MarkView, captured originals, reporting, idle tracking, and the simulated network (fetch, XMLHttpRequest, WebSocket, EventSource).
(function (A, config) {
  'use strict';
  Object.assign(A, {
    ask, connect, deliver, deliverChannel, noteActivity, notify, report, sameServer, send, surface, whenIdle
  });

  if (!config || window.__markviewStudio) return;
  var handlers = window.webkit && window.webkit.messageHandlers;
  var bridge = handlers && handlers.markviewStudio;
  if (!bridge) return;
  A.ready = true;
  var postToNative = bridge.postMessage.bind(bridge);

  var RealDate = Date;
  A.RealDate = RealDate;
  var realRandom = Math.random;
  var realFetch = window.fetch ? window.fetch.bind(window) : null;
  var RealXHR = window.XMLHttpRequest;
  var RealWebSocket = window.WebSocket;
  var RealEventSource = window.EventSource;
  var realSetTimeout = window.setTimeout.bind(window);
  A.realSetTimeout = realSetTimeout;
  var realClearTimeout = window.clearTimeout.bind(window);
  var realRAF = window.requestAnimationFrame ? window.requestAnimationFrame.bind(window) : function (f) { return realSetTimeout(f, 16); };
  A.realRAF = realRAF;
  var realReportError = typeof window.reportError === 'function' ? window.reportError : null;
  A.realReportError = realReportError;
  // A handler of the page threw while a simulated object (XHR, WebSocket, EventSource, Notification) called it. Rethrowing
  // from here made WebKit hide its message: the throw was in this script, which has no URL, so the page and its error overlay
  // only saw "Script error." (BUG-079). reportError hands the page the error itself, as an uncaught error of its own.
  function surface(error) {
    if (realReportError) {
      try { realReportError.call(window, error); return; } catch (ignored) {}
    }
    realSetTimeout(function () { throw error; }, 0);
  }

  // MARK: Bridge

  var counter = 0;
  function nextRequestId() {
    counter += 1;
    return 'g' + config.generation + '-' + counter + '-' + Math.floor(realRandom() * 2176782336).toString(36);
  }

  function send(message) {
    message.session = config.session;
    message.generation = config.generation;
    try { return Promise.resolve(postToNative(message)); } catch (error) { return Promise.reject(error); }
  }

  var reported = Object.create(null);
  var reportCount = 0;
  function report(type, detail, url) {
    var text = String(detail == null ? '' : detail).slice(0, 19000);
    var key = type + '\n' + text;
    if (reported[key] || reportCount > 300) return;
    reported[key] = true;
    reportCount += 1;
    send({ kind: 'event', type: type, detail: text, url: url || location.href }).catch(function () {});
  }
  // A route or a recorded step is reported every time.
  function notify(type, detail) {
    send({ kind: 'event', type: type, detail: String(detail).slice(0, 19000), url: location.href }).catch(function () {});
  }

  var loopback = { 'localhost': 1, '127.0.0.1': 1, '[::1]': 1, '::1': 1 };
  function sameServer(href) {
    try {
      var a = new URL(href, location.href);
      var b = location;
      var port = function (u) { return u.port || (u.protocol === 'https:' || u.protocol === 'wss:' ? '443' : '80'); };
      var hosts = a.hostname === b.hostname || (loopback[a.hostname] && loopback[b.hostname]);
      return !!hosts && port(a) === port(b);
    } catch (error) { return false; }
  }

  // MARK: Activity and idle

  A.pending = 0;
  var lastActivity = performance.now();
  A.loaded = document.readyState === 'complete';
  function noteActivity() { lastActivity = performance.now(); }
  window.addEventListener('load', function () { A.loaded = true; noteActivity(); });

  function whenIdle(timeoutMs, quietMs) {
    var deadline = performance.now() + (timeoutMs || 5000);
    var quiet = quietMs || 400;
    return new Promise(function (resolve) {
      (function check() {
        var now = performance.now();
        if (A.loaded && A.pending === 0 && now - lastActivity >= quiet) return resolve({ idle: true, pending: 0 });
        if (now >= deadline) return resolve({ idle: false, pending: A.pending });
        realSetTimeout(check, 50);
      })();
    });
  }
  whenIdle(60000).then(function (state) { if (state.idle) notify('idle', location.href); });

  // MARK: Requests

  function abortError(signal) {
    return signal && signal.reason !== undefined ? signal.reason : new DOMException('The operation was aborted.', 'AbortError');
  }

  function wait(ms, signal) {
    return new Promise(function (resolve, reject) {
      if (signal && signal.aborted) return reject(abortError(signal));
      var timer = realSetTimeout(resolve, ms);
      if (signal) signal.addEventListener('abort', function () { realClearTimeout(timer); reject(abortError(signal)); }, { once: true });
    });
  }

  // The loading state: the answer never comes, unless the request is aborted.
  function never(signal) {
    return new Promise(function (_, reject) {
      if (!signal) return;
      if (signal.aborted) return reject(abortError(signal));
      signal.addEventListener('abort', function () { reject(abortError(signal)); }, { once: true });
    });
  }

  function deliver(reply, signal) {
    if (reply.hang) return never(signal);
    if (reply.delayMs > 0) return wait(Math.min(reply.delayMs, 120000), signal);
    return Promise.resolve();
  }

  function ask(details, signal) {
    if (signal && signal.aborted) return Promise.reject(abortError(signal));
    details.kind = 'request';
    details.requestId = nextRequestId();
    // A Socket.IO long-poll waits for the server's next message by design: it does not keep the page busy.
    var counted = !(/[?&]EIO=\d/.test(details.url) && /[?&]transport=polling/.test(details.url)) ? 1 : 0;
    A.pending += counted;
    noteActivity();
    return send(details).then(function (reply) {
      A.pending -= counted;
      noteActivity();
      if (!reply || (reply.action !== 'pass' && reply.action !== 'respond')) {
        throw new TypeError('MarkView UI Studio did not answer ' + details.method + ' ' + details.url);
      }
      return reply;
    }, function (error) {
      A.pending -= counted;
      noteActivity();
      throw new TypeError('Failed to fetch (MarkView UI Studio: ' + ((error && error.message) || error) + ')');
    });
  }

  function headersObject(headers) {
    var out = {};
    if (!headers) return out;
    try { new Headers(headers).forEach(function (value, name) { out[name] = value; }); } catch (error) {}
    return out;
  }

  var statusTexts = { 200: 'OK', 201: 'Created', 202: 'Accepted', 204: 'No Content', 301: 'Moved Permanently', 302: 'Found',
    304: 'Not Modified', 400: 'Bad Request', 401: 'Unauthorized', 403: 'Forbidden', 404: 'Not Found', 405: 'Method Not Allowed',
    409: 'Conflict', 422: 'Unprocessable Entity', 429: 'Too Many Requests', 500: 'Internal Server Error', 501: 'Not Implemented',
    502: 'Bad Gateway', 503: 'Service Unavailable', 504: 'Gateway Timeout' };
  function statusText(status) { return statusTexts[status] || ''; }

  function makeResponse(reply, url) {
    var status = Math.min(599, Math.max(200, reply.status | 0));
    var nullBody = status === 204 || status === 205 || status === 304;
    var body = nullBody ? null : (reply.body == null ? '' : String(reply.body));
    var response = new Response(body, { status: status, statusText: statusText(status), headers: reply.headers || {} });
    try { Object.defineProperty(response, 'url', { value: url }); } catch (error) {}
    return response;
  }

  function bodyText(body) {
    if (body == null) return Promise.resolve(null);
    if (typeof body === 'string') return Promise.resolve(body);
    if (body instanceof URLSearchParams) return Promise.resolve(body.toString());
    if (typeof Blob !== 'undefined' && body instanceof Blob) return body.text();
    if (body instanceof ArrayBuffer) return Promise.resolve(new TextDecoder().decode(new Uint8Array(body)));
    if (ArrayBuffer.isView(body)) return Promise.resolve(new TextDecoder().decode(new Uint8Array(body.buffer, body.byteOffset, body.byteLength)));
    if (typeof FormData !== 'undefined' && body instanceof FormData) return new Response(body).text();
    if (typeof Document !== 'undefined' && body instanceof Document) return Promise.resolve(new XMLSerializer().serializeToString(body));
    return Promise.resolve(String(body));
  }

  // A pass-through may add headers on the way to the server (e.g. no-cache for a framework's data request).
  function withHeaders(request, headers) {
    if (!headers || typeof headers !== 'object') return request;
    var merged = new Headers(request.headers);
    Object.keys(headers).forEach(function (name) { merged.set(name, String(headers[name])); });
    return new Request(request, { headers: merged });
  }

  if (realFetch) {
    var studioFetch = function fetch(input, init) {
      var request;
      try { request = new Request(input, init); } catch (error) { return Promise.reject(error); }
      if (!/^https?:/i.test(request.url)) return realFetch(input, init);
      var signal = request.signal;
      var read = request.method === 'GET' || request.method === 'HEAD' ? Promise.resolve(null) : request.clone().text();
      return read.then(function (body) {
        return ask({ method: request.method, url: request.url, headers: headersObject(request.headers), body: body, transport: 'fetch' }, signal);
      }).then(function (reply) {
        if (reply.action === 'pass') return realFetch(withHeaders(request, reply.headers));
        return deliver(reply, signal).then(function () { return makeResponse(reply, request.url); });
      });
    };
    window.fetch = studioFetch;
  }

  // MARK: XMLHttpRequest

  var XHR_EVENTS = ['readystatechange', 'loadstart', 'progress', 'abort', 'error', 'load', 'timeout', 'loadend'];
  var STATIC_FILE = /\.(m?js|cjs|jsx|tsx?|css|scss|less|svg|png|jpe?g|gif|webp|avif|ico|woff2?|ttf|otf|eot|map|html?|txt|wasm|mp4|webm|mp3|wav)$/i;

  function fireOn(target, type, loaded, total) {
    var event;
    if (type === 'readystatechange') {
      event = new Event(type);
    } else {
      event = new ProgressEvent(type, { lengthComputable: total > 0, loaded: loaded || 0, total: total || 0 });
    }
    var handler = target['on' + type];
    if (typeof handler === 'function') {
      try { handler.call(target, event); } catch (error) { surface(error); }
    }
    target.dispatchEvent(event);
  }

  class StudioXHRUpload extends EventTarget {
    constructor() {
      super();
      for (var i = 0; i < XHR_EVENTS.length; i++) if (XHR_EVENTS[i] !== 'readystatechange') this['on' + XHR_EVENTS[i]] = null;
    }
  }

  class StudioXHR extends EventTarget {
    constructor() {
      super();
      this.upload = new StudioXHRUpload();
      for (var i = 0; i < XHR_EVENTS.length; i++) this['on' + XHR_EVENTS[i]] = null;
      this._real = null;
      this._mode = null;
      this._reset();
      this._readyState = 0;
      this._responseType = '';
      this._timeout = 0;
      this._withCredentials = false;
      this._mime = null;
    }

    _reset() {
      this._headers = {};
      this._sent = false;
      this._aborted = false;
      this._done = false;
      this._status = 0;
      this._statusText = '';
      this._responseHeaders = {};
      this._text = '';
      this._response = null;
      this._responseURL = '';
      this._controller = null;
      if (this._timer) realClearTimeout(this._timer);
      this._timer = null;
    }

    get readyState() { return this._mode === 'pass' ? this._real.readyState : this._readyState; }
    get status() { return this._mode === 'pass' ? this._real.status : this._status; }
    get statusText() { return this._mode === 'pass' ? this._real.statusText : this._statusText; }
    get responseURL() { return this._mode === 'pass' ? this._real.responseURL : this._responseURL; }
    get responseType() { return this._responseType; }
    set responseType(value) { this._responseType = String(value); if (this._real) this._real.responseType = this._responseType; }
    get timeout() { return this._timeout; }
    set timeout(value) { this._timeout = Number(value) || 0; if (this._real) this._real.timeout = this._timeout; }
    get withCredentials() { return this._withCredentials; }
    set withCredentials(value) { this._withCredentials = !!value; if (this._real) this._real.withCredentials = this._withCredentials; }
    get responseText() {
      if (this._mode === 'pass') return this._real.responseText;
      if (this._responseType !== '' && this._responseType !== 'text') {
        throw new DOMException("responseText is only available if responseType is '' or 'text'.", 'InvalidStateError');
      }
      return this._text;
    }
    get response() {
      if (this._mode === 'pass') return this._real.response;
      if (this._responseType === '' || this._responseType === 'text') return this._text;
      return this._readyState === 4 ? this._response : null;
    }
    get responseXML() {
      if (this._mode === 'pass') return this._real.responseXML;
      if (this._readyState !== 4 || (this._responseType !== '' && this._responseType !== 'document')) return null;
      try { return new DOMParser().parseFromString(this._text, /xml/.test(this._responseHeaders['content-type'] || '') ? 'application/xml' : 'text/html'); }
      catch (error) { return null; }
    }

    open(method, url, async, user, password) {
      if (this._real && this._mode === 'pass') { try { this._real.abort(); } catch (error) {} }
      this._real = null;
      this._mode = null;
      if (this._controller) this._controller.abort();
      this._reset();
      this._token = (this._token || 0) + 1;
      this._method = String(method).toUpperCase();
      this._url = new URL(String(url), location.href).href;
      this._async = async !== false;
      this._user = user;
      this._password = password;
      this._setState(1);
    }

    setRequestHeader(name, value) {
      if (this._readyState !== 1 || this._sent) throw new DOMException('The object is in an invalid state.', 'InvalidStateError');
      var key = String(name).toLowerCase();
      this._headers[key] = key in this._headers ? this._headers[key] + ', ' + value : String(value);
    }

    getResponseHeader(name) {
      if (this._mode === 'pass') return this._real.getResponseHeader(name);
      if (this._readyState < 2) return null;
      var value = this._responseHeaders[String(name).toLowerCase()];
      return value === undefined ? null : value;
    }

    getAllResponseHeaders() {
      if (this._mode === 'pass') return this._real.getAllResponseHeaders();
      if (this._readyState < 2) return '';
      var headers = this._responseHeaders;
      return Object.keys(headers).sort().map(function (name) { return name + ': ' + headers[name]; }).join('\r\n') + (Object.keys(headers).length ? '\r\n' : '');
    }

    overrideMimeType(mime) { this._mime = String(mime); if (this._real) this._real.overrideMimeType(this._mime); }

    send(body) {
      if (this._readyState !== 1 || this._sent) throw new DOMException('The object is in an invalid state.', 'InvalidStateError');
      this._sent = true;
      var self = this;
      var token = this._token;
      var current = function () { return self._token === token && !self._aborted && !self._done; };
      if (!/^https?:/i.test(this._url)) return this._pass(body, false);
      if (!this._async) {
        // A synchronous request cannot wait for MarkView: a static file of the app passes, anything else fails.
        if (sameServer(this._url) && STATIC_FILE.test(new URL(this._url).pathname)) return this._pass(body, false);
        report('unsupported', 'A synchronous XMLHttpRequest to ' + this._url + ' (UI Studio answers requests asynchronously).', this._url);
        throw new DOMException('Synchronous requests are not simulated by MarkView UI Studio.', 'NetworkError');
      }
      this._controller = new AbortController();
      var signal = this._controller.signal;
      fireOn(this, 'loadstart', 0, 0);
      if (this._timeout > 0) {
        this._timer = realSetTimeout(function () { self._finishWith('timeout'); }, this._timeout);
      }
      var noBody = this._method === 'GET' || this._method === 'HEAD';
      (noBody ? Promise.resolve(null) : bodyText(body)).then(function (text) {
        return ask({ method: self._method, url: self._url, headers: self._headers, body: text, transport: 'xhr' }, signal);
      }).then(function (reply) {
        if (!current()) return;
        if (reply.action === 'pass') return self._pass(body, true, reply.headers);
        self._mode = 'sim';
        if (!noBody && body != null) self._uploadEvents(body);
        return deliver(reply, signal).then(function () { if (current()) self._simulate(reply); });
      }).catch(function () {
        if (!current()) return;
        self._finishWith('error');
      });
    }

    abort() {
      if (this._mode === 'pass' && this._real) { this._real.abort(); return; }
      if (this._sent && !this._done) this._finishWith('abort');
      this._readyState = 0;
    }

    _setState(state) {
      this._readyState = state;
      fireOn(this, 'readystatechange');
    }

    _finishWith(type) {
      if (this._done) return;
      this._done = true;
      this._aborted = type === 'abort' || type === 'timeout';
      if (this._controller) this._controller.abort();
      if (this._timer) realClearTimeout(this._timer);
      this._status = 0;
      this._statusText = '';
      this._setState(4);
      fireOn(this, type, 0, 0);
      fireOn(this, 'loadend', 0, 0);
    }

    _uploadEvents(body) {
      var size = typeof body === 'string' ? body.length : (body && body.size) || (body && body.byteLength) || 0;
      fireOn(this.upload, 'loadstart', 0, size);
      fireOn(this.upload, 'progress', size, size);
      fireOn(this.upload, 'load', size, size);
      fireOn(this.upload, 'loadend', size, size);
    }

    _simulate(reply) {
      if (this._aborted || this._done) return;
      if (this._timer) realClearTimeout(this._timer);
      var headers = {};
      var given = reply.headers || {};
      Object.keys(given).forEach(function (name) { headers[name.toLowerCase()] = String(given[name]); });
      this._status = reply.status | 0;
      this._statusText = statusText(this._status);
      this._responseHeaders = headers;
      this._responseURL = this._url;
      this._setState(2);
      var text = reply.body == null ? '' : String(reply.body);
      this._text = text;
      this._setState(3);
      fireOn(this, 'progress', text.length, text.length);
      this._response = this._typed(text, headers['content-type'] || '');
      this._done = true;
      this._setState(4);
      fireOn(this, 'load', text.length, text.length);
      fireOn(this, 'loadend', text.length, text.length);
    }

    _typed(text, type) {
      switch (this._responseType) {
        case 'json': try { return text === '' ? null : JSON.parse(text); } catch (error) { return null; }
        case 'blob': return new Blob([text], { type: this._mime || type });
        case 'arraybuffer': return new TextEncoder().encode(text).buffer;
        case 'document': return this.responseXML;
        default: return text;
      }
    }

    _pass(body, started, added) {
      var self = this;
      var real = new RealXHR();
      this._real = real;
      this._mode = 'pass';
      real.open(this._method, this._url, this._async, this._user, this._password);
      Object.keys(this._headers).forEach(function (name) { real.setRequestHeader(name, self._headers[name]); });
      if (added && typeof added === 'object') Object.keys(added).forEach(function (name) { real.setRequestHeader(name, String(added[name])); });
      if (this._responseType && this._async) real.responseType = this._responseType;
      if (this._timeout && this._async) real.timeout = this._timeout;
      real.withCredentials = this._withCredentials;
      if (this._mime) real.overrideMimeType(this._mime);
      XHR_EVENTS.forEach(function (type) {
        if (started && type === 'loadstart') return;
        real.addEventListener(type, function (event) { fireOn(self, type, event.loaded, event.total); });
        if (type !== 'readystatechange') {
          real.upload.addEventListener(type, function (event) { fireOn(self.upload, type, event.loaded, event.total); });
        }
      });
      real.send(body);
    }
  }
  ['UNSENT', 'OPENED', 'HEADERS_RECEIVED', 'LOADING', 'DONE'].forEach(function (name, value) {
    Object.defineProperty(StudioXHR, name, { value: value });
    Object.defineProperty(StudioXHR.prototype, name, { value: value });
  });
  if (RealXHR) window.XMLHttpRequest = StudioXHR;

  // MARK: Connections (REQ-015)

  // The application's own development server keeps its sockets: hot reload (Vite, webpack-dev-server, Next.js and
  // Turbopack, Nuxt, Angular, sockjs, Metro, Storybook, livereload) and anything else on the dev server's origin that is
  // not a known API path. Every other WebSocket and EventSource talks to MarkView's simulated channels over the bridge;
  // none reaches a real service. `/ws` alone is webpack-dev-server's; `/ws/<more>` is the application's.
  var HOT_RELOAD_PATH = /^\/(ws|hmr|hot|ng-cli-ws|__vite_ping|livereload)$|^\/(sockjs-node|__webpack_hmr|storybook-server-channel)(\/|$)|^\/(@vite|_next|__nextjs|__turbopack|_nuxt)\/|webpack-hmr|turbopack-hmr/;
  var HOT_RELOAD_PROTOCOL = /^(vite-hmr|vite-ping)$/;
  var API_PATH = /(^|\/)(socket\.io|graphql|subscriptions?|realtime|cable|api|sse|events|stream|channels?|ws|websockets?|sockets?|live|chat|notifications?|pubsub|hubs?|rpc)(\/|$)/i;

  function keepsReal(absolute, protocols) {
    var url;
    try { url = new URL(absolute); } catch (error) { return false; }
    var hotProtocol = protocols.some(function (p) { return HOT_RELOAD_PROTOCOL.test(p); });
    if (hotProtocol && loopback[url.hostname]) return true;
    if (!sameServer(absolute)) return false;
    return hotProtocol || HOT_RELOAD_PATH.test(url.pathname) || !API_PATH.test(url.pathname);
  }

  var STATE = typeof Symbol === 'function' ? Symbol('markview-channel') : '__markviewChannel';
  var channels = Object.create(null);
  A.channels = channels;
  var channelCounter = 0;
  function nextChannelId() {
    channelCounter += 1;
    return 'c' + config.generation + '-' + channelCounter + '-' + Math.floor(realRandom() * 2176782336).toString(36);
  }

  function bufferToBase64(buffer) {
    var bytes = new Uint8Array(buffer);
    var text = '';
    for (var i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(text);
  }

  function base64ToBuffer(text) {
    var raw = atob(text || '');
    var bytes = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i += 1) bytes[i] = raw.charCodeAt(i);
    return bytes.buffer;
  }

  // An `on…` handler, then the listeners; an error of the application's handler surfaces as an uncaught error.
  function fire(target, event) {
    var handler = target['on' + event.type];
    if (typeof handler === 'function') {
      try { handler.call(target, event); } catch (error) { surface(error); }
    }
    EventTarget.prototype.dispatchEvent.call(target, event);
  }

  function originOf(href) {
    try { return new URL(href).origin; } catch (error) { return ''; }
  }

  function finish(state, code, reason, clean) {
    if (state.readyState === state.closedState) return;
    state.readyState = state.closedState;
    delete channels[state.id];
    if (state.transport === 'websocket') fire(state.target, new CloseEvent('close', { code: code, reason: reason || '', wasClean: clean }));
  }

  function fail(state, reason) {
    if (state.readyState === state.closedState) return;
    var target = state.target;
    state.readyState = state.closedState;
    delete channels[state.id];
    fire(target, new Event('error'));
    if (state.transport === 'websocket') fire(target, new CloseEvent('close', { code: 1006, reason: '', wasClean: false }));
    if (reason) console.warn('MarkView UI Studio: ' + state.url + ': ' + reason);
  }

  function receive(state, frames) {
    for (var i = 0; i < frames.length; i += 1) {
      var frame = frames[i];
      if (state.readyState !== 1) return;
      if (frame.type === 'close') {
        finish(state, frame.code || 1005, frame.reason, true);
        return;
      }
      var data = frame.data;
      if (frame.type === 'binary') {
        var buffer = base64ToBuffer(frame.data);
        data = state.target.binaryType === 'arraybuffer' ? buffer : new Blob([buffer]);
      }
      var type = frame.type === 'event' ? (frame.event || 'message') : 'message';
      fire(state.target, new MessageEvent(type, { data: data, origin: originOf(state.url), lastEventId: frame.id || '' }));
    }
  }

  function connect(target, absolute, protocols, transport) {
    var state = { id: nextChannelId(), target: target, url: absolute, transport: transport, readyState: 0, protocol: '',
      closedState: transport === 'websocket' ? 3 : 2, early: [], chain: Promise.resolve() };
    channels[state.id] = state;
    A.pending += 1;
    noteActivity();
    send({ kind: 'channel', action: 'open', id: state.id, url: absolute, protocols: protocols, transport: transport }).then(function (reply) {
      A.pending -= 1;
      noteActivity();
      if (state.readyState !== 0) {
        if (reply && reply.ok) send({ kind: 'channel', action: 'close', id: state.id, code: 1000 }).catch(function () {});
        return;
      }
      if (!reply || !reply.ok) return fail(state, reply && reply.reason);
      state.protocol = reply.protocol || '';
      state.readyState = 1;
      fire(target, new Event('open'));
      receive(state, reply.frames || []);
      var early = state.early;
      state.early = [];
      receive(state, early);
    }, function (error) {
      A.pending -= 1;
      noteActivity();
      fail(state, (error && error.message) || String(error));
    });
    return state;
  }

  function payloadOf(data) {
    if (typeof data === 'string') return Promise.resolve({ text: data });
    if (data instanceof ArrayBuffer) return Promise.resolve({ binary: bufferToBase64(data) });
    if (ArrayBuffer.isView(data)) return Promise.resolve({ binary: bufferToBase64(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)) });
    if (typeof Blob !== 'undefined' && data instanceof Blob) return data.arrayBuffer().then(function (buffer) { return { binary: bufferToBase64(buffer) }; });
    return Promise.resolve({ text: String(data) });
  }

  function deliverChannel(id, frames) {
    var state = channels[id];
    if (!state || !frames || !frames.length) return false;
    if (state.readyState === 0) state.early = state.early.concat(frames); else receive(state, frames);
    return true;
  }

  if (RealWebSocket) {
    var StudioWebSocket = class WebSocket extends EventTarget {
      constructor(url, protocols) {
        if (arguments.length === 0) throw new TypeError("Failed to construct 'WebSocket': 1 argument required, but only 0 present.");
        var absolute;
        try {
          var parsed = new URL(String(url), location.href);
          if (parsed.protocol === 'http:') parsed.protocol = 'ws:';
          if (parsed.protocol === 'https:') parsed.protocol = 'wss:';
          if (parsed.protocol !== 'ws:' && parsed.protocol !== 'wss:') throw new Error('scheme');
          parsed.hash = '';
          absolute = parsed.href;
        } catch (error) {
          throw new DOMException("Failed to construct 'WebSocket': The URL '" + String(url) + "' is invalid.", 'SyntaxError');
        }
        var list = protocols == null ? [] : [].concat(protocols).map(String);
        if (keepsReal(absolute, list)) return protocols === undefined ? new RealWebSocket(url) : new RealWebSocket(url, protocols);
        super();
        this.onopen = null;
        this.onmessage = null;
        this.onerror = null;
        this.onclose = null;
        var state = connect(this, absolute, list, 'websocket');
        state.binaryType = 'blob';
        this[STATE] = state;
      }
      get url() { return this[STATE].url; }
      get readyState() { return this[STATE].readyState; }
      get protocol() { return this[STATE].protocol; }
      get extensions() { return ''; }
      get bufferedAmount() { return 0; }
      get binaryType() { return this[STATE].binaryType; }
      set binaryType(value) { if (value === 'blob' || value === 'arraybuffer') this[STATE].binaryType = value; }
      send(data) {
        var state = this[STATE];
        if (state.readyState === 0) throw new DOMException("Failed to execute 'send' on 'WebSocket': Still in CONNECTING state.", 'InvalidStateError');
        if (state.readyState !== 1) return;
        var payload = payloadOf(data);
        state.chain = state.chain.then(function () { return payload; }).then(function (message) {
          if (state.readyState !== 1) return;
          message.kind = 'channel';
          message.action = 'send';
          message.id = state.id;
          return send(message).then(function (reply) { if (reply && reply.frames) receive(state, reply.frames); });
        }).catch(function () {});
      }
      close(code, reason) {
        var state = this[STATE];
        if (code !== undefined && code !== 1000 && !(code >= 3000 && code <= 4999)) {
          throw new DOMException("Failed to execute 'close' on 'WebSocket': The close code must be either 1000, or between 3000 and 4999.", 'InvalidAccessError');
        }
        var text = reason === undefined ? '' : String(reason);
        if (new TextEncoder().encode(text).length > 123) throw new DOMException("Failed to execute 'close' on 'WebSocket': The close reason must not be greater than 123 UTF-8 bytes.", 'SyntaxError');
        if (state.readyState === 2 || state.readyState === 3) return;
        var connecting = state.readyState === 0;
        state.readyState = 2;
        if (!connecting) send({ kind: 'channel', action: 'close', id: state.id, code: code === undefined ? 1000 : code, reason: text }).catch(function () {});
        // Closing while connecting fails the connection (error, then close 1006), as in a browser.
        realSetTimeout(function () {
          if (connecting) return fail(state, '');
          finish(state, code === undefined ? 1005 : code, text, true);
        }, 0);
      }
      static [Symbol.hasInstance](object) {
        return object instanceof RealWebSocket || Function.prototype[Symbol.hasInstance].call(this, object);
      }
    };
    ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'].forEach(function (name, value) {
      Object.defineProperty(StudioWebSocket, name, { value: value });
      Object.defineProperty(StudioWebSocket.prototype, name, { value: value });
    });
    window.WebSocket = StudioWebSocket;
  }

  if (RealEventSource) {
    var StudioEventSource = class EventSource extends EventTarget {
      constructor(url, options) {
        if (arguments.length === 0) throw new TypeError("Failed to construct 'EventSource': 1 argument required, but only 0 present.");
        var absolute;
        try { absolute = new URL(String(url), location.href).href; } catch (error) {
          throw new DOMException("Failed to construct 'EventSource': Cannot open an EventSource to '" + String(url) + "'. The URL is invalid.", 'SyntaxError');
        }
        if (keepsReal(absolute, [])) return new RealEventSource(url, options);
        super();
        this.onopen = null;
        this.onmessage = null;
        this.onerror = null;
        var state = connect(this, absolute, [], 'eventsource');
        state.withCredentials = !!(options && options.withCredentials);
        this[STATE] = state;
      }
      get url() { return this[STATE].url; }
      get readyState() { return this[STATE].readyState; }
      get withCredentials() { return this[STATE].withCredentials; }
      close() {
        var state = this[STATE];
        if (state.readyState === 2) return;
        var open = state.readyState === 1;
        state.readyState = 2;
        delete channels[state.id];
        if (open) send({ kind: 'channel', action: 'close', id: state.id, code: 1000 }).catch(function () {});
      }
      static [Symbol.hasInstance](object) {
        return object instanceof RealEventSource || Function.prototype[Symbol.hasInstance].call(this, object);
      }
    };
    ['CONNECTING', 'OPEN', 'CLOSED'].forEach(function (name, value) {
      Object.defineProperty(StudioEventSource, name, { value: value });
      Object.defineProperty(StudioEventSource.prototype, name, { value: value });
    });
    window.EventSource = StudioEventSource;
  }

  if (navigator.sendBeacon) {
    navigator.sendBeacon = function sendBeacon(url) {
      report('unsupported', 'navigator.sendBeacon(' + String(url) + ') was not sent (beacons are not simulated).', String(url));
      return true;
    };
  }

  // MARK: Reproducible seed, time and locale
})(window.__markviewStudioParts = {}, __MARKVIEW_STUDIO_CONFIG__);
