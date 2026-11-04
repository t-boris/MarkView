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
// - Uncaught errors, the dev server's build error overlay, blocked resources, route changes, Electron stand-in calls and
//   "the page is idle" are reported.
// - Select mode: hover highlights, a click selects without running the element's action, parent navigation; the selection
//   carries what the framework's development metadata says about its source and its repeated instances.
// - Restoration steps are recorded and replayed; a capture freezes animations and hides the overlay.
//
// The API for MarkView is `window.__markviewStudio`. The project is trusted local code (REQ-006): this runtime is a
// test harness in the page, not a security boundary, and every message it sends is validated again natively.
(function (config) {
  'use strict';
  if (!config || window.__markviewStudio) return;
  var handlers = window.webkit && window.webkit.messageHandlers;
  var bridge = handlers && handlers.markviewStudio;
  if (!bridge) return;
  var postToNative = bridge.postMessage.bind(bridge);

  var RealDate = Date;
  var realRandom = Math.random;
  var realFetch = window.fetch ? window.fetch.bind(window) : null;
  var RealXHR = window.XMLHttpRequest;
  var RealWebSocket = window.WebSocket;
  var RealEventSource = window.EventSource;
  var realSetTimeout = window.setTimeout.bind(window);
  var realClearTimeout = window.clearTimeout.bind(window);
  var realRAF = window.requestAnimationFrame ? window.requestAnimationFrame.bind(window) : function (f) { return realSetTimeout(f, 16); };

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

  var pending = 0;
  var lastActivity = performance.now();
  var loaded = document.readyState === 'complete';
  function noteActivity() { lastActivity = performance.now(); }
  window.addEventListener('load', function () { loaded = true; noteActivity(); });

  function whenIdle(timeoutMs, quietMs) {
    var deadline = performance.now() + (timeoutMs || 5000);
    var quiet = quietMs || 400;
    return new Promise(function (resolve) {
      (function check() {
        var now = performance.now();
        if (loaded && pending === 0 && now - lastActivity >= quiet) return resolve({ idle: true, pending: 0 });
        if (now >= deadline) return resolve({ idle: false, pending: pending });
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
    pending += counted;
    noteActivity();
    return send(details).then(function (reply) {
      pending -= counted;
      noteActivity();
      if (!reply || (reply.action !== 'pass' && reply.action !== 'respond')) {
        throw new TypeError('MarkView UI Studio did not answer ' + details.method + ' ' + details.url);
      }
      return reply;
    }, function (error) {
      pending -= counted;
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
      try { handler.call(target, event); } catch (error) { realSetTimeout(function () { throw error; }); }
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
      try { handler.call(target, event); } catch (error) { realSetTimeout(function () { throw error; }, 0); }
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
    pending += 1;
    noteActivity();
    send({ kind: 'channel', action: 'open', id: state.id, url: absolute, protocols: protocols, transport: transport }).then(function (reply) {
      pending -= 1;
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
      pending -= 1;
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

  var seedState = (config.seed >>> 0) || 1;
  Math.random = function random() {
    seedState = (seedState + 0x6D2B79F5) >>> 0;
    var t = seedState;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };

  if (typeof config.testTime === 'number' && isFinite(config.testTime)) {
    // The clock shows testTime at MarkView's anchor (the real time of the last restore) and runs on across page loads; the
    // development server's clock shares the anchor (DEC-006). Within a page it advances with the monotonic clock.
    var anchor = typeof config.clockAnchor === 'number' && isFinite(config.clockAnchor) ? config.clockAnchor : RealDate.now();
    var startTime = config.testTime + Math.max(0, RealDate.now() - anchor);
    var startPerf = performance.now();
    var studioNow = function () { return Math.floor(startTime + (performance.now() - startPerf)); };
    var StudioDate = function Date() {
      if (!new.target) return new RealDate(studioNow()).toString();
      if (arguments.length === 0) return new RealDate(studioNow());
      var args = Array.prototype.slice.call(arguments);
      return new (Function.prototype.bind.apply(RealDate, [null].concat(args)))();
    };
    StudioDate.prototype = RealDate.prototype;
    RealDate.prototype.constructor = StudioDate;
    StudioDate.now = studioNow;
    StudioDate.parse = RealDate.parse;
    StudioDate.UTC = RealDate.UTC;
    window.Date = StudioDate;
  }

  if (config.locale) {
    var studioLocale = String(config.locale);
    var zone = config.timeZone ? String(config.timeZone) : null;
    var withZone = function (options) { return zone ? Object.assign({ timeZone: zone }, options || {}) : options; };
    try {
      Object.defineProperty(Navigator.prototype, 'language', { get: function () { return studioLocale; }, configurable: true });
      Object.defineProperty(Navigator.prototype, 'languages', { get: function () { return [studioLocale]; }, configurable: true });
    } catch (error) {}
    var wrapIntl = function (name, zoned) {
      var Real = Intl[name];
      if (!Real) return;
      var Wrapped = function (locales, options) {
        return new Real(locales === undefined ? studioLocale : locales, zoned ? withZone(options) : options);
      };
      Wrapped.prototype = Real.prototype;
      Wrapped.supportedLocalesOf = Real.supportedLocalesOf.bind(Real);
      Intl[name] = Wrapped;
    };
    wrapIntl('DateTimeFormat', true);
    ['NumberFormat', 'Collator', 'PluralRules', 'RelativeTimeFormat', 'ListFormat'].forEach(function (name) { wrapIntl(name, false); });
    ['toLocaleString', 'toLocaleDateString', 'toLocaleTimeString'].forEach(function (name) {
      var real = RealDate.prototype[name];
      RealDate.prototype[name] = function (locales, options) { return real.call(this, locales === undefined ? studioLocale : locales, withZone(options)); };
    });
    var realNumberLocale = Number.prototype.toLocaleString;
    Number.prototype.toLocaleString = function (locales, options) { return realNumberLocale.call(this, locales === undefined ? studioLocale : locales, options); };
  }

  // MARK: Browser features (REQ-008)
  //
  // Location, permissions, the clipboard, camera and microphone, and notifications answer from the scenario's browser
  // settings (`config.browser`). The Mac's own are never used: the page gets the scenario's place, a clipboard of its
  // own, a blank test stream and notifications that are listed in Studio. Each use is reported as a `browser` event;
  // clipboard contents never are.

  var browser = config.browser || {};
  var place = browser.location && browser.location.kind === 'place' && isFinite(browser.location.latitude)
    && isFinite(browser.location.longitude) ? browser.location : null;
  var locationKind = place ? 'place' : (browser.location && browser.location.kind === 'unavailable' ? 'unavailable' : 'denied');
  var mediaGranted = browser.media === 'testStream';
  var notificationPermission = browser.notifications === 'granted' || browser.notifications === 'denied' ? browser.notifications : 'default';
  var pageClipboard = typeof browser.clipboardText === 'string' ? browser.clipboardText : '';

  // A use of the same kind is reported once per page; clipboard writes and notifications every time, up to a bound.
  var browserNotes = 0;
  function browserUse(detail, everyTime) {
    if (!everyTime) return report('browser', detail);
    if (browserNotes >= 100) return;
    browserNotes += 1;
    notify('browser', detail);
  }

  function ownValues(object, values) {
    Object.keys(values).forEach(function (name) {
      Object.defineProperty(object, name, { value: values[name], writable: true, enumerable: true, configurable: true });
    });
    return object;
  }
  // An object that passes `instanceof` for the platform's type (its accessors are shadowed by own values).
  function shaped(Type) { return typeof Type === 'function' && Type.prototype ? Object.create(Type.prototype) : {}; }
  function withEvents(object) {
    var events = new EventTarget();
    return ownValues(object, { addEventListener: events.addEventListener.bind(events), removeEventListener: events.removeEventListener.bind(events),
      dispatchEvent: events.dispatchEvent.bind(events) });
  }
  function later(callback) { realSetTimeout(callback, 0); }
  function onNavigator(name, value) {
    try { Object.defineProperty(Navigator.prototype, name, { get: function () { return value; }, enumerable: true, configurable: true }); } catch (error) {}
  }
  function quoted(text, limit) { return JSON.stringify(String(text).slice(0, limit)); }

  // Location: the scenario's place, or PERMISSION_DENIED (1) or POSITION_UNAVAILABLE (2), always asynchronously. The
  // position's timestamp is the session's test clock.
  function positionError(code) {
    return ownValues(shaped(window.GeolocationPositionError), { code: code, PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3,
      message: code === 1 ? 'User denied Geolocation' : 'The position is unavailable (MarkView UI Studio scenario)' });
  }
  function scenarioPosition() {
    var values = { latitude: +place.latitude, longitude: +place.longitude, accuracy: +place.accuracy > 0 ? +place.accuracy : 25,
      altitude: null, altitudeAccuracy: null, heading: null, speed: null };
    var coords = ownValues(shaped(window.GeolocationCoordinates), values);
    ownValues(coords, { toJSON: function () { return Object.assign({}, values); } });
    var position = ownValues(shaped(window.GeolocationPosition), { coords: coords, timestamp: Date.now() });
    return ownValues(position, { toJSON: function () { return { coords: coords.toJSON(), timestamp: position.timestamp }; } });
  }
  function locate(success, failure) {
    browserUse('geolocation: ' + (place ? 'place ' + quoted(place.label || '', 200) : locationKind));
    if (place) {
      success(scenarioPosition());
    } else if (typeof failure === 'function') {
      failure(positionError(locationKind === 'unavailable' ? 2 : 1));
    }
  }
  function needsCallback(method, success) {
    if (typeof success !== 'function') {
      throw new TypeError("Failed to execute '" + method + "' on 'Geolocation': parameter 1 is not a function.");
    }
  }
  var watches = Object.create(null);
  var watchCount = 0;
  onNavigator('geolocation', ownValues(shaped(window.Geolocation), {
    getCurrentPosition: function getCurrentPosition(success, failure) {
      needsCallback('getCurrentPosition', success);
      later(function () { locate(success, failure); });
    },
    // The place does not move: a watch answers once and stays until it is cleared.
    watchPosition: function watchPosition(success, failure) {
      needsCallback('watchPosition', success);
      watchCount += 1;
      var id = watchCount;
      watches[id] = true;
      later(function () { if (watches[id]) locate(success, failure); });
      return id;
    },
    clearWatch: function clearWatch(id) { delete watches[id]; }
  }));

  // Permissions: the states of the scenario for the features it answers; any other name is asked of the browser.
  function permissionState(name) {
    switch (name) {
      case 'geolocation': return locationKind === 'denied' ? 'denied' : 'granted';
      case 'notifications': return notificationPermission === 'default' ? 'prompt' : notificationPermission;
      case 'camera': case 'microphone': return mediaGranted ? 'granted' : 'denied';
      case 'clipboard-read': case 'clipboard-write': return 'granted';
      default: return null;
    }
  }
  var realPermissions = navigator.permissions || null;
  var realQuery = realPermissions && typeof realPermissions.query === 'function' ? realPermissions.query.bind(realPermissions) : null;
  var studioQuery = function query(descriptor) {
    var name = descriptor && descriptor.name !== undefined ? String(descriptor.name) : '';
    var state = permissionState(name);
    if (state === null) {
      return realQuery ? realQuery(descriptor) : Promise.reject(new TypeError("Failed to execute 'query' on 'Permissions': unknown permission name."));
    }
    browserUse('permissions: ' + name + ' is ' + state);
    return Promise.resolve(withEvents(ownValues(shaped(window.PermissionStatus), { name: name, state: state, onchange: null })));
  };
  if (realPermissions) {
    try { Object.defineProperty(realPermissions, 'query', { value: studioQuery, writable: true, configurable: true }); } catch (error) {}
  } else {
    onNavigator('permissions', ownValues(shaped(window.Permissions), { query: studioQuery }));
  }

  // Clipboard: the page has a clipboard of its own that starts with the scenario's text; writes replace it and are
  // reported by size, never reaching the Mac's clipboard.
  function clipboardWritten(text, types) {
    if (text !== null) pageClipboard = text;
    var parts = [];
    if (text !== null) parts.push(text.length + ' chars');
    if (types && types.length) parts.push(types.join(', ').slice(0, 200));
    browserUse('clipboard: write (' + (parts.join(', ') || 'empty') + ')', true);
  }
  function clipboardRead() { browserUse('clipboard: read (' + pageClipboard.length + ' chars)'); }
  onNavigator('clipboard', withEvents(ownValues(shaped(window.Clipboard), {
    readText: function readText() {
      clipboardRead();
      return Promise.resolve(pageClipboard);
    },
    writeText: function writeText(text) {
      clipboardWritten(String(text), null);
      return Promise.resolve();
    },
    read: function read() {
      clipboardRead();
      var blob = new Blob([pageClipboard], { type: 'text/plain' });
      if (typeof ClipboardItem === 'function') return Promise.resolve([new ClipboardItem({ 'text/plain': blob })]);
      return Promise.resolve([{ types: ['text/plain'], presentationStyle: 'unspecified',
        getType: function (type) { return type === 'text/plain' ? Promise.resolve(blob) : Promise.reject(new DOMException('No such type.', 'NotFoundError')); } }]);
    },
    // Never rejects: the page's items are read as far as they can be, and only their sizes and types are reported.
    write: function write(items) {
      var list = [];
      try { list = Array.prototype.slice.call(items || []); } catch (error) {}
      return Promise.all(list.map(function (item) {
        var types = [];
        try { types = Array.prototype.slice.call((item && item.types) || []).map(String); } catch (error) {}
        if (types.indexOf('text/plain') < 0) return { types: types, text: null };
        return Promise.resolve().then(function () { return item.getType('text/plain'); })
          .then(function (blob) { return typeof blob === 'string' ? blob : blob.text(); })
          .then(function (text) { return { types: types, text: String(text) }; }, function () { return { types: types, text: null }; });
      })).then(function (parts) {
        var text = null;
        var types = [];
        parts.forEach(function (part) {
          part.types.forEach(function (type) { if (types.indexOf(type) < 0) types.push(type); });
          if (text === null && part.text !== null) text = part.text;
        });
        clipboardWritten(text, types.filter(function (type) { return type !== 'text/plain'; }));
      });
    }
  })));
  // document.execCommand('copy') and 'cut' (the classic copy of copy-to-clipboard libraries) write to the page's
  // clipboard too: the copy event lets the page set the data, as a real copy does; otherwise the selection is copied.
  var realExecCommand = Document.prototype.execCommand;
  if (realExecCommand) {
    Document.prototype.execCommand = function execCommand(command) {
      var name = String(command).toLowerCase();
      if (name !== 'copy' && name !== 'cut') return realExecCommand.apply(this, arguments);
      var active = document.activeElement;
      var field = active && (active.tagName === 'TEXTAREA' || active.tagName === 'INPUT') && typeof active.selectionStart === 'number' ? active : null;
      var data = null;
      var event = null;
      try { data = new DataTransfer(); event = new ClipboardEvent(name, { bubbles: true, cancelable: true, composed: true, clipboardData: data }); } catch (error) {}
      if (event) (active || document.body || document.documentElement).dispatchEvent(event);
      var text;
      if (event && event.defaultPrevented && data) text = data.getData('text/plain');
      else if (field) text = field.value.slice(field.selectionStart, field.selectionEnd);
      else text = String(window.getSelection ? window.getSelection() : '');
      clipboardWritten(text, null);
      if (name === 'cut' && !(event && event.defaultPrevented) && (field || (active && active.isContentEditable))) realExecCommand.call(this, 'delete');
      return true;
    };
  }

  // Camera and microphone: denied (NotAllowedError) or a test stream: a blank canvas video track and a silent WebAudio
  // track. No device is opened; the devices listed are test devices.
  function dimension(value, fallback) {
    var number = typeof value === 'number' ? value : value && (value.ideal || value.exact || value.max || value.min);
    number = Math.round(+number);
    return number >= 16 && number <= 4096 ? number : fallback;
  }
  function labelled(track, label) {
    try { Object.defineProperty(track, 'label', { value: label, configurable: true }); } catch (error) {}
    return track;
  }
  function testVideoTrack(constraints) {
    var canvas = document.createElement('canvas');
    var wanted = constraints && typeof constraints === 'object' ? constraints : {};
    canvas.width = dimension(wanted.width, 640);
    canvas.height = dimension(wanted.height, 480);
    if (typeof canvas.captureStream !== 'function') return null;
    var context = canvas.getContext('2d');
    var paint = function () { context.fillStyle = '#202124'; context.fillRect(0, 0, canvas.width, canvas.height); };
    paint();
    var track = canvas.captureStream(15).getVideoTracks()[0] || null;
    // A canvas stream makes frames when the canvas is drawn: the same picture is drawn while the track is live.
    (function frame() {
      if (!track || track.readyState === 'ended') return;
      paint();
      realSetTimeout(frame, 250);
    })();
    return track && labelled(track, 'MarkView Test Camera');
  }
  var testAudio = null;
  function testAudioTrack() {
    var Context = window.AudioContext || window.webkitAudioContext;
    if (!Context) return null;
    try {
      testAudio = testAudio || new Context();
      var oscillator = testAudio.createOscillator();
      var silence = testAudio.createGain();
      silence.gain.value = 0;
      var destination = testAudio.createMediaStreamDestination();
      oscillator.connect(silence);
      silence.connect(destination);
      oscillator.start();
      var track = destination.stream.getAudioTracks()[0] || null;
      return track && labelled(track, 'MarkView Test Microphone');
    } catch (error) {
      return null;
    }
  }
  function mediaKinds(video, audio) { return [video ? 'camera' : null, audio ? 'microphone' : null].filter(Boolean).join(' and '); }
  function studioGetUserMedia(constraints) {
    var video = !!(constraints && constraints.video);
    var audio = !!(constraints && constraints.audio);
    if (!video && !audio) return Promise.reject(new TypeError('At least one of audio and video must be requested.'));
    return new Promise(function (resolve, reject) {
      later(function () {
        if (!mediaGranted) {
          browserUse('media: ' + mediaKinds(video, audio) + ' denied');
          return reject(new DOMException('The request is not allowed by the user agent or the platform in the current context, possibly because the user denied permission.', 'NotAllowedError'));
        }
        var tracks = [];
        var missing = [];
        if (video) { var picture = testVideoTrack(constraints.video); if (picture) tracks.push(picture); else missing.push('camera'); }
        if (audio) { var sound = testAudioTrack(); if (sound) tracks.push(sound); else missing.push('microphone'); }
        if (missing.length || typeof MediaStream !== 'function') {
          browserUse('media: test stream unavailable for the ' + (missing.join(' and ') || mediaKinds(video, audio)));
          return reject(new DOMException('The test stream could not be made in this page.', 'NotReadableError'));
        }
        browserUse('media: test stream for the ' + mediaKinds(video, audio));
        resolve(new MediaStream(tracks));
      });
    });
  }
  function testDevice(kind, label, id) {
    var Type = kind === 'audiooutput' ? window.MediaDeviceInfo : (window.InputDeviceInfo || window.MediaDeviceInfo);
    // Without permission a browser lists one device per kind with neither label nor id.
    var values = { deviceId: mediaGranted ? id : '', groupId: mediaGranted ? 'markview-test-devices' : '', kind: kind, label: mediaGranted ? label : '' };
    var device = ownValues(shaped(Type), values);
    ownValues(device, { toJSON: function () { return Object.assign({}, values); } });
    if (kind !== 'audiooutput') ownValues(device, { getCapabilities: function () { return {}; } });
    return device;
  }
  var realMedia = navigator.mediaDevices || null;
  onNavigator('mediaDevices', withEvents(ownValues(shaped(window.MediaDevices), {
    ondevicechange: null,
    getUserMedia: studioGetUserMedia,
    enumerateDevices: function enumerateDevices() {
      browserUse('media: devices listed');
      return Promise.resolve([testDevice('audioinput', 'MarkView Test Microphone', 'markview-test-microphone'),
        testDevice('videoinput', 'MarkView Test Camera', 'markview-test-camera'),
        testDevice('audiooutput', 'MarkView Test Speakers', 'markview-test-speakers')]);
    },
    getSupportedConstraints: function getSupportedConstraints() {
      try { if (realMedia) return realMedia.getSupportedConstraints(); } catch (error) {}
      return { width: true, height: true, aspectRatio: true, frameRate: true, facingMode: true, deviceId: true, groupId: true };
    },
    getDisplayMedia: function getDisplayMedia() {
      return new Promise(function (_, reject) {
        later(function () {
          browserUse('media: screen sharing denied');
          reject(new DOMException('Screen sharing is not simulated by MarkView UI Studio.', 'NotAllowedError'));
        });
      });
    }
  })));
  ['getUserMedia', 'webkitGetUserMedia'].forEach(function (name) {
    if (!(name in navigator)) return;
    onNavigator(name, function (constraints, success, failure) {
      studioGetUserMedia(constraints).then(success, failure);
    });
  });

  // Notifications: the permission is the scenario's; a notification is listed in Studio (title and body) instead of shown.
  var closedNotifications = new WeakSet();
  function fireNotification(notification, type) {
    var event = new Event(type);
    var handler = notification['on' + type];
    if (typeof handler === 'function') { try { handler.call(notification, event); } catch (error) { realSetTimeout(function () { throw error; }); } }
    notification.dispatchEvent(event);
  }
  class StudioNotification extends EventTarget {
    constructor(title, options) {
      super();
      if (arguments.length === 0) throw new TypeError("Failed to construct 'Notification': 1 argument required, but only 0 present.");
      var settings = options || {};
      this.title = String(title);
      this.body = settings.body == null ? '' : String(settings.body);
      this.tag = settings.tag == null ? '' : String(settings.tag);
      this.icon = settings.icon == null ? '' : String(settings.icon);
      this.dir = settings.dir || 'auto';
      this.lang = settings.lang || '';
      this.data = settings.data === undefined ? null : settings.data;
      this.silent = settings.silent == null ? null : !!settings.silent;
      this.requireInteraction = !!settings.requireInteraction;
      this.onclick = null;
      this.onshow = null;
      this.onerror = null;
      this.onclose = null;
      var shown = notificationPermission === 'granted';
      browserUse('notifications: ' + (shown ? 'shown ' : 'not shown (permission ' + notificationPermission + ') ') + quoted(this.title, 200)
        + (this.body ? ' — ' + this.body.slice(0, 500) : ''), true);
      var self = this;
      later(function () { fireNotification(self, shown ? 'show' : 'error'); });
    }
    close() {
      if (closedNotifications.has(this)) return;
      closedNotifications.add(this);
      var self = this;
      later(function () { fireNotification(self, 'close'); });
    }
    static get permission() { return notificationPermission; }
    static get maxActions() { return 0; }
    static requestPermission(callback) {
      browserUse('notifications: permission requested, answered ' + notificationPermission);
      if (typeof callback === 'function') later(function () { callback(notificationPermission); });
      return Promise.resolve(notificationPermission);
    }
  }
  try { Object.defineProperty(window, 'Notification', { value: StudioNotification, writable: true, configurable: true }); } catch (error) {}

  // MARK: Kept browser data (REQ-008)

  // The localStorage entries the person kept are written once per generation, before the application's own scripts:
  // later pages of the same generation keep what the application changed since. A restore empties sessionStorage too,
  // so each generation starts without the marker.
  var KEPT_MARKER = 'markview-ui-studio-kept';
  (function writeKeptStorage() {
    var entries = Array.isArray(config.keptStorage) ? config.keptStorage : [];
    if (!entries.length) return;
    try {
      if (sessionStorage.getItem(KEPT_MARKER) === String(config.generation)) return;
      entries.forEach(function (entry) {
        if (entry && typeof entry.key === 'string' && typeof entry.value === 'string') localStorage.setItem(entry.key, entry.value);
      });
      sessionStorage.setItem(KEPT_MARKER, String(config.generation));
    } catch (error) {}
  })();

  // The page's localStorage, for "Keep this page's cookies and storage": MarkView decides what may be kept.
  function storageEntries() {
    var entries = [];
    try {
      for (var i = 0; i < localStorage.length && entries.length < 500; i++) {
        var key = localStorage.key(i);
        if (key !== null) entries.push({ key: key, value: localStorage.getItem(key) || '' });
      }
    } catch (error) {}
    return { origin: location.origin, entries: entries };
  }

  // MARK: Errors, build overlays, blocked resources, routes

  window.addEventListener('error', function (event) {
    var target = event.target;
    if (target && target !== window && target.tagName) {
      var source = target.currentSrc || target.src || target.href || '';
      if (source && !sameServer(source)) report('blocked', target.tagName.toLowerCase() + ' ' + source, source);
      return;
    }
    var where = event.filename ? ' (' + event.filename + ':' + event.lineno + ':' + event.colno + ')' : '';
    var stack = event.error && event.error.stack ? '\n' + String(event.error.stack).slice(0, 4000) : '';
    report('runtimeError', (event.message || 'Error') + where + stack);
  }, true);

  window.addEventListener('unhandledrejection', function (event) {
    var reason = event.reason;
    report('runtimeError', 'Unhandled rejection: ' + String((reason && (reason.stack || reason.message)) || reason).slice(0, 4000));
  });

  var buildError = '';
  function overlayText() {
    var vite = document.querySelector('vite-error-overlay');
    if (vite) {
      var root = vite.shadowRoot;
      var message = root && (root.querySelector('.message') || root.querySelector('.window'));
      return 'Vite: ' + ((message || root || vite).textContent || 'build error').trim();
    }
    var webpack = document.getElementById('webpack-dev-server-client-overlay');
    if (webpack) {
      try { return 'webpack: ' + (webpack.contentDocument.body.innerText || 'build error').trim(); } catch (error) { return 'webpack: build error'; }
    }
    var next = document.querySelector('nextjs-portal');
    if (next && next.shadowRoot) {
      // Next.js shows every issue in the same dialog and names its kind in the label: "Build Error"
      // ("Failed to compile" before Next 15) is a build failure; "Console Error", "Runtime Error",
      // "Recoverable Error", "Blocking Route"… are issues of a page that built.
      var label = next.shadowRoot.querySelector('#nextjs__container_errors_label, #nextjs__container_build_error_label');
      if (label && /^\s*(build error|failed to compile)/i.test(label.textContent || '')) {
        var dialog = next.shadowRoot.querySelector('[data-nextjs-dialog], [data-nextjs-error-overlay]');
        return 'Next.js: ' + ((dialog || label).textContent || 'build error').trim();
      }
    }
    return '';
  }
  // Sent on every change, not deduplicated: an empty detail tells the app the build error is gone,
  // and the same error coming back must be reported again.
  function checkOverlay() {
    var text = overlayText().slice(0, 8000);
    if (text === buildError) return;
    buildError = text;
    notify('buildError', text);
  }
  var watchedPortal = null;
  function watchOverlays() {
    var observer = new MutationObserver(check);
    function check() {
      // Next.js opens and closes its dialog inside the shadow root of a portal that stays on the page.
      var portal = document.querySelector('nextjs-portal');
      if (portal && portal.shadowRoot && portal !== watchedPortal) {
        watchedPortal = portal;
        observer.observe(portal.shadowRoot, { childList: true, subtree: true });
      }
      checkOverlay();
    }
    if (document.body) observer.observe(document.body, { childList: true });
    observer.observe(document.documentElement, { childList: true });
    check();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', watchOverlays); else watchOverlays();

  ['pushState', 'replaceState'].forEach(function (name) {
    var real = history[name];
    history[name] = function () {
      var result = real.apply(this, arguments);
      noteActivity();
      notify('route', location.pathname + location.search + location.hash);
      return result;
    };
  });
  window.addEventListener('popstate', function () { noteActivity(); notify('route', location.pathname + location.search + location.hash); });
  window.addEventListener('hashchange', function () { noteActivity(); notify('route', location.pathname + location.search + location.hash); });

  // The address the person last typed into the page at (BUG-074): an automatic reload for simulation rules that arrived
  // late would lose that text, so MarkView asks before reloading.
  var typedOn = null;
  document.addEventListener('input', function (event) { if (event.isTrusted) typedOn = location.pathname + location.search; }, true);

  // MARK: Electron renderer stand-ins

  if (config.electron) {
    var standIn = function (path) {
      return new Proxy(function () {}, {
        get: function (_, key) {
          if (key === 'then') return undefined;
          if (key === Symbol.iterator) return function* () {};
          if (key === Symbol.toPrimitive) return function () { return ''; };
          if (typeof key === 'symbol') return undefined;
          return standIn(path + '.' + String(key));
        },
        apply: function () {
          // A stand-in does nothing: the scenario that depends on it is not simulated (REQ-001).
          report('electron', path + '()');
          return standIn(path + '()');
        }
      });
    };
    var names = config.electronGlobals && config.electronGlobals.length ? config.electronGlobals
      : ['electron', 'api', 'ipcRenderer', 'electronAPI', 'bridge', 'desktop'];
    names.forEach(function (name) { if (/^[A-Za-z_$][\w$]*$/.test(name) && !(name in window)) window[name] = standIn('window.' + name); });
  }

  // MARK: Source metadata of frameworks (development builds)

  function tagLabel(el) {
    var text = el.tagName.toLowerCase();
    if (el.id) text += '#' + el.id;
    var classes = (typeof el.className === 'string' ? el.className : (el.getAttribute('class') || '')).trim().split(/\s+/).filter(Boolean).slice(0, 3);
    if (classes.length) text += '.' + classes.join('.');
    return text;
  }

  // The element's place under `root`: tag and position among siblings of the same tag.
  function pathFrom(root, el) {
    var parts = [];
    for (var node = el; node && node !== root && node.nodeType === 1; node = node.parentElement) {
      var index = 1;
      for (var sibling = node.previousElementSibling; sibling; sibling = sibling.previousElementSibling) if (sibling.tagName === node.tagName) index += 1;
      parts.unshift(node.tagName.toLowerCase() + ':' + index);
      if (parts.length > 30) break;
    }
    return parts.join('/');
  }

  function expando(el, prefixes) {
    var keys = Object.keys(el);
    for (var i = 0; i < keys.length; i++) {
      for (var j = 0; j < prefixes.length; j++) if (keys[i].indexOf(prefixes[j]) === 0) return el[keys[i]];
    }
    return null;
  }

  function componentName(type) {
    if (!type) return '';
    if (typeof type === 'function') return type.displayName || type.name || '';
    if (typeof type === 'object') return type.displayName || componentName(type.render) || componentName(type.type) || '';
    return '';
  }

  // The first frame of the application's own code: its URL and position. A bundled chunk's position is mapped back to
  // the source file by MarkView through the chunk's source map (BUG-069).
  function frameOf(stack) {
    var lines = String(stack || '').split('\n');
    for (var i = 0; i < lines.length; i++) {
      var match = /(https?:\/\/[^\s()]+?):(\d+):(\d+)/.exec(lines[i]);
      if (!match) continue;
      if (/node_modules|\/@vite\/|\/@react-refresh|react-dom|jsx-dev-runtime|\.vite\/deps|chunk-[A-Z0-9]+\.js|%5Bturbopack%5D|\[turbopack\]/.test(match[1])) continue;
      return { url: match[1].replace(/\?.*$/, ''), line: +match[2], column: +match[3] };
    }
    return null;
  }

  function reactSource(el) {
    var fiber = expando(el, ['__reactFiber$', '__reactInternalInstance$']);
    if (!fiber) return null;
    var owner = fiber.return;
    while (owner && typeof owner.type === 'string') owner = owner.return;
    var name = owner ? componentName(owner.type) : '';
    var source = fiber._debugSource;
    if (source && source.fileName) {
      return { framework: 'react', mapping: 'exact', file: source.fileName, line: source.lineNumber, column: source.columnNumber || 0,
        component: name, nodeId: source.fileName + ':' + source.lineNumber + ':' + (source.columnNumber || 0) };
    }
    // React 19: no element locations; the component's file comes from the stack captured when the element was made.
    // The element's own stack points at its JSX; the owner's at where the component itself was used.
    var own = frameOf(fiber._debugStack && fiber._debugStack.stack);
    var frame = own || (owner && frameOf(owner._debugStack && owner._debugStack.stack));
    var file = frame ? frame.url : '';
    var rootEl = el;
    for (var node = el.parentElement; node; node = node.parentElement) {
      var f = expando(node, ['__reactFiber$']);
      var o = f && f.return;
      while (o && typeof o.type === 'string') o = o.return;
      if (!owner || (o !== owner && o !== owner.alternate)) break;
      rootEl = node;
    }
    return { framework: 'react', mapping: file ? 'component' : 'none', file: file, component: name,
      generatedLine: frame ? frame.line : 0, generatedColumn: frame ? frame.column : 0, generatedOwn: !!own,
      nodeId: (file || 'react') + '|' + name + '|' + pathFrom(rootEl.parentElement, el) };
  }

  function vueSource(el) {
    var instance = el.__vueParentComponent;
    if (instance) {
      var type = instance.type || {};
      var root = instance.subTree && instance.subTree.el && instance.subTree.el.nodeType === 1 ? instance.subTree.el : null;
      var file = type.__file || '';
      return { framework: 'vue', mapping: file ? 'component' : 'none', file: file, component: type.name || type.__name || '',
        instanceId: 'vue:' + instance.uid, nodeId: (file || 'vue') + '|' + pathFrom(root ? root.parentElement : null, el) };
    }
    for (var node = el; node; node = node.parentElement) {
      if (node.__vue__) {
        var options = node.__vue__.$options || {};
        return { framework: 'vue', mapping: options.__file ? 'component' : 'none', file: options.__file || '', component: options.name || '',
          instanceId: 'vue:' + node.__vue__._uid, nodeId: (options.__file || 'vue') + '|' + pathFrom(node.parentElement, el) };
      }
    }
    return null;
  }

  function svelteSource(el) {
    var meta = el.__svelte_meta;
    if (!meta || !meta.loc || !meta.loc.file) return null;
    // Svelte 3/4 count lines from 0 (and record a character offset); MarkView checks the line against the file.
    var line = (meta.loc.line | 0) + (typeof meta.loc.char === 'number' ? 1 : 0);
    return { framework: 'svelte', mapping: 'exact', file: meta.loc.file, line: line, column: (meta.loc.column | 0) + 1,
      nodeId: meta.loc.file + ':' + line + ':' + ((meta.loc.column | 0) + 1) };
  }

  function angularSource(el) {
    var ng = window.ng;
    if (!ng || typeof ng.getOwningComponent !== 'function') return null;
    var component = null;
    try { component = ng.getComponent(el) || ng.getOwningComponent(el); } catch (error) { return null; }
    if (!component) return null;
    var name = component.constructor && component.constructor.name || '';
    var host = null;
    try { host = ng.getHostElement(component); } catch (error) {}
    return { framework: 'angular', mapping: 'component', file: '', component: name,
      nodeId: 'ng:' + name + '|' + pathFrom(host, el) };
  }

  function inspectorAttributes(el) {
    var vue = el.getAttribute('data-v-inspector');
    if (vue) {
      var parts = /^(.*):(\d+):(\d+)$/.exec(vue);
      if (parts) return { framework: 'vue', mapping: 'exact', file: parts[1], line: +parts[2], column: +parts[3], nodeId: vue };
    }
    var file = el.getAttribute('data-inspector-relative-path') || el.getAttribute('data-source-file');
    var line = el.getAttribute('data-inspector-line') || el.getAttribute('data-source-line');
    if (file && line) {
      var column = el.getAttribute('data-inspector-column') || el.getAttribute('data-source-column') || '0';
      return { framework: 'inspector', mapping: 'exact', file: file, line: +line, column: +column, nodeId: file + ':' + line + ':' + column };
    }
    return null;
  }

  function sourceOf(el) {
    return inspectorAttributes(el) || reactSource(el) || vueSource(el) || svelteSource(el) || angularSource(el)
      || { framework: '', mapping: 'none', file: '', nodeId: '' };
  }

  // Which of the elements rendered from the same source node this one is (PRE-08).
  function instancesOf(el, source) {
    if (!source.nodeId) return { index: 0, count: 1, elements: [el] };
    var same = [];
    var candidates = document.getElementsByTagName(el.tagName);
    for (var i = 0; i < candidates.length && i < 5000; i++) {
      var candidate = candidates[i];
      if (candidate === el || sourceOf(candidate).nodeId === source.nodeId) same.push(candidate);
    }
    return { index: Math.max(0, same.indexOf(el)), count: Math.max(1, same.length), elements: same };
  }

  var STYLE_NAMES = ['display', 'position', 'box-sizing', 'width', 'height', 'min-width', 'max-width', 'margin-top', 'margin-right',
    'margin-bottom', 'margin-left', 'padding-top', 'padding-right', 'padding-bottom', 'padding-left', 'border-top-width',
    'border-right-width', 'border-bottom-width', 'border-left-width', 'border-style', 'border-color', 'border-radius', 'color',
    'background-color', 'background-image', 'font-family', 'font-size', 'font-weight', 'font-style', 'line-height', 'letter-spacing',
    'text-align', 'text-transform', 'text-decoration-line', 'white-space', 'gap', 'flex-direction', 'flex-wrap', 'flex-grow',
    'flex-shrink', 'flex-basis', 'justify-content', 'align-items', 'grid-template-columns', 'grid-template-rows', 'opacity',
    'box-shadow', 'z-index', 'overflow', 'cursor', 'transform'];
  function stylesOf(el) {
    var computed = getComputedStyle(el);
    var out = {};
    STYLE_NAMES.forEach(function (name) {
      var value = computed.getPropertyValue(name);
      if (value) out[name] = value.length > 300 ? value.slice(0, 300) + '…' : value;
    });
    return out;
  }

  // A selector that finds the element again for a replay: a test id or a unique id, else a path of tag positions.
  function selectorOf(el) {
    var attrs = ['data-testid', 'data-test', 'data-cy', 'data-qa'];
    for (var i = 0; i < attrs.length; i++) {
      var value = el.getAttribute(attrs[i]);
      if (value) {
        var bySelector = '[' + attrs[i] + '="' + CSS.escape(value) + '"]';
        if (document.querySelectorAll(bySelector).length === 1) return bySelector;
      }
    }
    if (el.id && document.querySelectorAll('#' + CSS.escape(el.id)).length === 1) return '#' + CSS.escape(el.id);
    var parts = [];
    for (var node = el; node && node.nodeType === 1 && node !== document.documentElement; node = node.parentElement) {
      if (node !== el && node.id && document.querySelectorAll('#' + CSS.escape(node.id)).length === 1) { parts.unshift('#' + CSS.escape(node.id)); break; }
      var index = 1;
      for (var sibling = node.previousElementSibling; sibling; sibling = sibling.previousElementSibling) if (sibling.tagName === node.tagName) index += 1;
      parts.unshift(node.tagName.toLowerCase() + ':nth-of-type(' + index + ')');
    }
    return parts.join(' > ');
  }

  function boundaryOf(el, source) {
    var tag = el.tagName.toLowerCase();
    if (tag === 'iframe' || tag === 'frame') return 'An embedded frame: elements inside it cannot be selected.';
    if (tag === 'canvas') return 'A canvas: what it draws has no elements to select.';
    if (el.tagName.indexOf('-') > 0 && el.shadowRoot === null && !el.children.length && !el.textContent.trim()
        && el.getBoundingClientRect().width > 0) return 'A custom element whose content may be in a closed shadow root: its inner elements cannot be selected.';
    if (source.mapping === 'none') return 'No development source metadata links this element to a file (a production build or an unsupported framework).';
    return '';
  }

  function similarElements(fingerprint) {
    var tag = String(fingerprint && fingerprint.tag || '').toLowerCase();
    if (!/^[a-z][a-z0-9-]*$/.test(tag)) return [];
    var component = String(fingerprint.component || '');
    var classes = Array.isArray(fingerprint.classes) ? fingerprint.classes.map(String) : [];
    var text = String(fingerprint.text || '').replace(/\s+/g, ' ').trim().slice(0, 120);
    var list = document.getElementsByTagName(tag), out = [];
    for (var i = 0; i < list.length && i < 5000 && out.length < 50; i++) {
      var el = list[i];
      if (host && (el === host || host.contains(el))) continue;
      if (component) {
        if ((sourceOf(el).component || '') !== component) continue;
      } else if (classes.length || text) {
        var shares = classes.some(function (name) { return el.classList.contains(name); });
        var own = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 120);
        if (!shares && !(text && own === text)) continue;
      }
      out.push(el);
    }
    return out;
  }

  function describe(el) {
    var rect = el.getBoundingClientRect();
    var source = sourceOf(el);
    var instances = instancesOf(el, source);
    source.instanceIndex = instances.index;
    source.instanceCount = instances.count;
    return {
      rect: { x: rect.left, y: rect.top, width: rect.width, height: rect.height },
      tag: tagLabel(el),
      selector: selectorOf(el),
      html: (el.outerHTML || '').slice(0, 40000),
      text: (el.innerText || el.textContent || '').trim().slice(0, 2000),
      // What identifies the element when its position changes (BUG-068): its classes, role and label.
      classes: Array.prototype.slice.call(el.classList || [], 0, 40),
      role: el.getAttribute('role') || '',
      label: (el.getAttribute('aria-label') || '').slice(0, 200),
      route: location.pathname + location.search + location.hash,
      url: location.href,
      styles: stylesOf(el),
      source: source,
      boundary: boundaryOf(el, source),
      parent: el.parentElement && el.parentElement !== document.documentElement ? tagLabel(el.parentElement) : '',
      viewport: { width: innerWidth, height: innerHeight, scrollX: scrollX, scrollY: scrollY }
    };
  }

  // MARK: Selection overlay

  var host = null;
  var layer = null;
  var hoverBox = null;
  var selectedBox = null;
  var instanceBoxes = [];
  var hovered = null;
  var selected = null;
  var siblings = [];
  var selecting = false;
  var pickResolve = null;
  var captureHidden = false;

  function ensureOverlay() {
    if (host && host.isConnected) return;
    host = document.createElement('markview-studio-overlay');
    host.style.cssText = 'position:fixed;inset:0;pointer-events:none;z-index:2147483647;display:block;';
    var root = host.attachShadow({ mode: 'closed' });
    layer = document.createElement('div');
    root.appendChild(layer);
    var box = function (css) {
      var div = document.createElement('div');
      div.style.cssText = 'position:fixed;box-sizing:border-box;display:none;pointer-events:none;' + css;
      layer.appendChild(div);
      return div;
    };
    hoverBox = box('border:1px dashed #3794ff;background:rgba(55,148,255,0.12);');
    var label = document.createElement('div');
    label.style.cssText = 'position:absolute;left:-1px;top:-20px;padding:0 6px;font:11px/18px -apple-system,system-ui,sans-serif;color:#fff;' +
      'background:#3794ff;white-space:nowrap;border-radius:3px;max-width:70vw;overflow:hidden;text-overflow:ellipsis;';
    hoverBox.appendChild(label);
    hoverBox.label = label;
    selectedBox = box('border:2px solid #f5a623;background:rgba(245,166,35,0.10);');
    document.documentElement.appendChild(host);
  }

  function place(div, el) {
    if (!el || !el.isConnected) { div.style.display = 'none'; return; }
    var r = el.getBoundingClientRect();
    div.style.display = captureHidden ? 'none' : 'block';
    div.style.left = r.left + 'px';
    div.style.top = r.top + 'px';
    div.style.width = r.width + 'px';
    div.style.height = r.height + 'px';
    if (div.label) div.label.style.top = r.top < 22 ? (r.height + 2) + 'px' : '-20px';
  }

  var scheduled = false;
  function redraw() {
    if (scheduled) return;
    scheduled = true;
    realRAF(function () {
      scheduled = false;
      if (!host) return;
      place(hoverBox, selecting ? hovered : null);
      place(selectedBox, selected);
      instanceBoxes.forEach(function (div, i) { place(div, siblings[i]); });
    });
  }
  window.addEventListener('scroll', redraw, { capture: true, passive: true });
  window.addEventListener('resize', redraw, { passive: true });

  function showInstances(elements) {
    ensureOverlay();
    instanceBoxes.forEach(function (div) { div.remove(); });
    instanceBoxes = [];
    siblings = elements.filter(function (el) { return el !== selected; }).slice(0, 60);
    siblings.forEach(function () {
      var div = document.createElement('div');
      div.style.cssText = 'position:fixed;box-sizing:border-box;display:none;pointer-events:none;border:1px dashed rgba(245,166,35,0.8);';
      layer.appendChild(div);
      instanceBoxes.push(div);
    });
  }

  function select(el) {
    ensureOverlay();
    selected = el;
    var description = describe(el);
    showInstances(instancesOf(el, description.source).elements);
    redraw();
    return description;
  }

  function targetOf(event) {
    var path = event.composedPath ? event.composedPath() : [event.target];
    for (var i = 0; i < path.length; i++) {
      var node = path[i];
      if (node && node.nodeType === 1 && node !== host) return node;
    }
    return null;
  }

  function swallow(event) {
    if (!selecting) return;
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
  }

  function onMove(event) {
    if (!selecting) return;
    swallow(event);
    var el = targetOf(event);
    if (!el || el === hovered) return;
    hovered = el;
    ensureOverlay();
    var r = el.getBoundingClientRect();
    hoverBox.label.textContent = tagLabel(el) + '  ' + Math.round(r.width) + '×' + Math.round(r.height);
    redraw();
  }

  function onClick(event) {
    if (!selecting) return;
    swallow(event);
    var el = targetOf(event);
    if (!el) return;
    var description = select(el);
    if (pickResolve) { var resolve = pickResolve; pickResolve = null; resolve(description); }
  }

  function onKey(event) {
    if (!selecting) return;
    if (event.key === 'Escape') {
      swallow(event);
      if (pickResolve) { var resolve = pickResolve; pickResolve = null; resolve(null); }
    } else if (event.type === 'keydown' || event.type === 'keypress' || event.type === 'keyup') {
      // Keys must not reach the page's shortcuts while selecting.
      swallow(event);
    }
  }

  ['mousemove', 'mouseover', 'mouseout', 'mouseenter', 'mouseleave', 'pointermove', 'pointerover', 'pointerout', 'pointerenter',
    'pointerleave'].forEach(function (type) { window.addEventListener(type, onMove, true); });
  window.addEventListener('click', onClick, true);
  ['mousedown', 'mouseup', 'pointerdown', 'pointerup', 'dblclick', 'auxclick', 'contextmenu', 'touchstart', 'touchend', 'submit',
    'dragstart', 'focusin'].forEach(function (type) { window.addEventListener(type, swallow, true); });
  ['keydown', 'keypress', 'keyup'].forEach(function (type) { window.addEventListener(type, onKey, true); });

  function setSelecting(on) {
    selecting = !!on;
    if (!selecting) {
      hovered = null;
      if (pickResolve) { var resolve = pickResolve; pickResolve = null; resolve(null); }
    }
    document.documentElement.style.cursor = selecting ? 'crosshair' : '';
    redraw();
    return selecting;
  }

  // MARK: Steps

  // A page loaded while recording records from its start (BUG-071).
  var recording = !!config.recording;
  var PASSWORD_PLACEHOLDER = 'markview-test-password';

  function recordStep(step) { notify('recorded', JSON.stringify(step)); }

  function actionTarget(el) {
    return el.closest('a,button,[role="button"],[role="link"],[role="tab"],[role="menuitem"],[role="option"],label,summary,input,select,textarea') || el;
  }

  // A click on a label clicks its control as well: only the label's click is a step.
  var labelControl = null;
  window.addEventListener('click', function (event) {
    if (!recording || selecting) return;
    var el = targetOf(event);
    if (!el) return;
    var target = actionTarget(el);
    if (labelControl && target === labelControl) { labelControl = null; return; }
    labelControl = target.tagName === 'LABEL' ? target.control : null;
    if (target.matches('input[type="text"],input:not([type]),input[type="email"],input[type="search"],input[type="password"],input[type="number"],textarea,select')) return;
    recordStep({ action: 'click', selector: selectorOf(target) });
  }, true);

  window.addEventListener('change', function (event) {
    if (!recording || selecting) return;
    var el = event.target;
    if (!el || !el.matches) return;
    if (el.matches('input[type="checkbox"],input[type="radio"]')) return;
    if (el.matches('input,textarea,select')) {
      var text = el.type === 'password' ? PASSWORD_PLACEHOLDER : String(el.value).slice(0, 2000);
      recordStep({ action: 'type', selector: selectorOf(el), text: text });
    }
  }, true);

  window.addEventListener('keydown', function (event) {
    if (!recording || selecting) return;
    if (event.key === 'Enter' || event.key === 'Escape') {
      var el = event.target && event.target.nodeType === 1 ? event.target : document.body;
      if (event.key === 'Enter' && el.matches && el.matches('input,textarea')) {
        var value = el.type === 'password' ? PASSWORD_PLACEHOLDER : String(el.value).slice(0, 2000);
        recordStep({ action: 'type', selector: selectorOf(el), text: value });
      }
      recordStep({ action: 'press', selector: selectorOf(el), text: event.key });
    }
  }, true);

  function sleep(ms) { return new Promise(function (resolve) { realSetTimeout(resolve, ms); }); }

  function waitFor(selector, timeoutMs) {
    var deadline = performance.now() + timeoutMs;
    return new Promise(function (resolve) {
      (function look() {
        var el = null;
        try { el = document.querySelector(selector); } catch (error) { return resolve(null); }
        if (el) return resolve(el);
        if (performance.now() >= deadline) return resolve(null);
        realSetTimeout(look, 50);
      })();
    });
  }

  function clickElement(el) {
    el.scrollIntoView({ block: 'center', inline: 'center' });
    var r = el.getBoundingClientRect();
    var init = { bubbles: true, cancelable: true, composed: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: 0 };
    el.dispatchEvent(new PointerEvent('pointerdown', init));
    el.dispatchEvent(new MouseEvent('mousedown', init));
    if (typeof el.focus === 'function') el.focus({ preventScroll: true });
    el.dispatchEvent(new PointerEvent('pointerup', init));
    el.dispatchEvent(new MouseEvent('mouseup', init));
    el.click();
  }

  function typeInto(el, text) {
    if (typeof el.focus === 'function') el.focus({ preventScroll: true });
    if (el.isContentEditable) {
      el.textContent = text;
    } else {
      var prototype = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
        : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
      var setter = Object.getOwnPropertyDescriptor(prototype, 'value').set;
      setter.call(el, text);
    }
    el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }

  function pressKey(el, key) {
    var init = { key: key, code: key, bubbles: true, cancelable: true, composed: true };
    el.dispatchEvent(new KeyboardEvent('keydown', init));
    el.dispatchEvent(new KeyboardEvent('keyup', init));
    if (key === 'Enter' && el.form && el.matches('input')) {
      if (typeof el.form.requestSubmit === 'function') el.form.requestSubmit(); else el.form.submit();
    }
  }

  function navigateTo(path) {
    var target = new URL(String(path), location.href);
    if (target.origin !== location.origin) throw new Error('A step may only navigate inside the application.');
    history.pushState({}, '', target.pathname + target.search + target.hash);
    window.dispatchEvent(new PopStateEvent('popstate', { state: {} }));
  }

  async function replay(steps) {
    var wasSelecting = selecting;
    setSelecting(false);
    try {
      for (var i = 0; i < steps.length; i++) {
        var step = steps[i] || {};
        if (step.action === 'wait') { await sleep(Math.min(Math.max(0, step.ms | 0), 10000)); continue; }
        if (step.action === 'navigate') { navigateTo(step.text || '/'); await whenIdle(5000, 200); continue; }
        var el = await waitFor(step.selector, 5000);
        if (!el) return { ok: false, step: i, reason: 'No element matches ' + step.selector + '.' };
        if (step.action === 'click') clickElement(el);
        else if (step.action === 'type') typeInto(el, step.text || '');
        else if (step.action === 'press') pressKey(el, step.text || 'Enter');
        else return { ok: false, step: i, reason: 'Unknown step ' + step.action + '.' };
        await whenIdle(4000, 200);
      }
      return { ok: true };
    } catch (error) {
      return { ok: false, step: i, reason: String((error && error.message) || error) };
    } finally {
      setSelecting(wasSelecting);
    }
  }

  // MARK: Captures

  var freezeStyle = null;
  async function prepareCapture() {
    captureHidden = true;
    if (host) host.style.display = 'none';
    if (!freezeStyle) {
      freezeStyle = document.createElement('style');
      freezeStyle.textContent = '*,*::before,*::after{animation-play-state:paused!important;animation-delay:0s!important;' +
        'transition:none!important;caret-color:transparent!important;scroll-behavior:auto!important}';
      document.documentElement.appendChild(freezeStyle);
    }
    if (document.getAnimations) {
      document.getAnimations().forEach(function (animation) {
        try { animation.currentTime = 0; animation.pause(); } catch (error) {}
      });
    }
    try { await document.fonts.ready; } catch (error) {}
    await new Promise(function (resolve) { realRAF(function () { realRAF(resolve); }); });
    return rendering();
  }

  function finishCapture() {
    captureHidden = false;
    if (host) host.style.display = 'block';
    if (freezeStyle) { freezeStyle.remove(); freezeStyle = null; }
    if (document.getAnimations) document.getAnimations().forEach(function (animation) { try { animation.play(); } catch (error) {} });
    redraw();
    return true;
  }

  function rendering() {
    var fonts = [];
    try {
      document.fonts.forEach(function (face) {
        if (face.status === 'loaded') {
          var family = face.family.replace(/^["']|["']$/g, '');
          if (fonts.indexOf(family) < 0) fonts.push(family);
        }
      });
    } catch (error) {}
    var options = new Intl.DateTimeFormat().resolvedOptions();
    var engine = /AppleWebKit\/([\d.]+)/.exec(navigator.userAgent);
    return {
      engine: engine ? 'WebKit ' + engine[1] : navigator.userAgent.slice(0, 120),
      width: innerWidth, height: innerHeight, devicePixelRatio: devicePixelRatio,
      fonts: fonts.sort(), locale: options.locale, timeZone: options.timeZone,
      colorScheme: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
    };
  }

  // MARK: API for MarkView

  var api = {
    version: 1,
    generation: config.generation,
    setSelecting: setSelecting,
    // Resolves with the element the person clicks in select mode; null when select mode ends or Escape is pressed.
    pick: function () {
      if (pickResolve) { var previous = pickResolve; pickResolve = null; previous(null); }
      setSelecting(true);
      return new Promise(function (resolve) { pickResolve = resolve; });
    },
    selected: function () { return selected && selected.isConnected ? describe(selected) : null; },
    parent: function () {
      if (!selected || !selected.isConnected) return null;
      var parent = selected.parentElement;
      if (!parent || parent === document.documentElement) return describe(selected);
      return select(parent);
    },
    child: function () {
      if (!selected || !selected.isConnected || !selected.firstElementChild) return null;
      return select(selected.firstElementChild);
    },
    clear: function () { selected = null; showInstances([]); redraw(); return true; },
    // The elements now matching a selector, described (to revalidate a selection after a change).
    candidates: function (selector) {
      var list = [];
      try { list = Array.prototype.slice.call(document.querySelectorAll(selector), 0, 50); } catch (error) { return []; }
      return list.map(describe);
    },
    selectMatching: function (selector, index) {
      var list = [];
      try { list = document.querySelectorAll(selector); } catch (error) { return null; }
      var el = list[index | 0] || list[0];
      return el ? select(el) : null;
    },
    // Elements that may be the selected one wherever they are now (BUG-068): the same tag and, when known, the same
    // component; otherwise sharing a class or the text. MarkView decides which of them, if any, is the same element.
    similar: function (fingerprint) { return similarElements(fingerprint).map(describe); },
    selectSimilar: function (fingerprint, index) {
      var el = similarElements(fingerprint)[index | 0];
      return el ? select(el) : null;
    },
    setRecording: function (on) { recording = !!on; return recording; },
    replay: replay,
    whenIdle: whenIdle,
    typedSinceRoute: function () { return typedOn === location.pathname + location.search; },
    prepareCapture: prepareCapture,
    finishCapture: finishCapture,
    rendering: rendering,
    storage: storageEntries,
    // Frames MarkView pushes to a simulated WebSocket or EventSource (REQ-015).
    deliver: deliverChannel,
    state: function () {
      return { pending: pending, loaded: loaded, buildError: overlayText().slice(0, 8000), route: location.pathname + location.search + location.hash,
        title: document.title };
    }
  };
  Object.defineProperty(window, '__markviewStudio', { value: Object.freeze(api), enumerable: false, configurable: false, writable: false });
})(__MARKVIEW_STUDIO_CONFIG__);
