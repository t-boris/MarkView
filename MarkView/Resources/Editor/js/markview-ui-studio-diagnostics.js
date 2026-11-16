// UI Studio page runtime, part 4 of 6: errors, the build error overlay, route changes and typing, and the framework source metadata.
(function (A, config) {
  'use strict';
  if (!A.ready) return;   // no configuration, already installed, or no bridge to MarkView (the first part returned early)
  const {
    activateStandIn, ask, channels, connect, deliver, noteActivity, notify, realReportError, realSetTimeout, report,
    sameServer, send
  } = A;
  Object.assign(A, { describe, instancesOf, overlayText, selectorOf, similarElements, tagLabel });

  // Errors the application hands to console.error or reportError (BUG-079). React and most frameworks pass the Error
  // object itself. WebKit hides the message and stack of an uncaught error thrown by a script of another origin or by a
  // script without an address: the error event only says "Script error.". What the application logged is then the
  // readable account of the crash.
  var lastLogged = null;
  function errorText(value) {
    if (!value || typeof value !== 'object') return null;
    var message = value.message, stack = value.stack;
    if (typeof message !== 'string' || typeof stack !== 'string') return null;
    var name = typeof value.name === 'string' && value.name ? value.name : 'Error';
    var head = name + ': ' + message;
    return (stack.indexOf(head) === 0 ? stack : head + '\n' + stack).slice(0, 4000);
  }
  function noteLogged(value, how) {
    var text = errorText(value);
    if (!text) return;
    lastLogged = { at: performance.now(), text: text };
    report('logged', how + ': ' + text);
  }
  if (window.console && typeof console.error === 'function') {
    var realConsoleError = console.error;
    console.error = function () {
      try {
        for (var i = 0; i < arguments.length; i++) {
          if (errorText(arguments[i])) { noteLogged(arguments[i], 'console.error'); break; }
        }
      } catch (error) {}
      return realConsoleError.apply(this, arguments);
    };
  }
  if (realReportError) {
    window.reportError = function (error) {
      try { noteLogged(error, 'reportError'); } catch (ignored) {}
      return realReportError.apply(this, arguments);
    };
  }

  window.addEventListener('error', function (event) {
    var target = event.target;
    if (target && target !== window && target.tagName) {
      var source = target.currentSrc || target.src || target.href || '';
      if (source && !sameServer(source)) {
        // A script of a registered SDK gets its stand-in and its `load` event instead of the page's `error` handlers.
        if (target.tagName === 'SCRIPT' && activateStandIn(target, source)) { event.stopImmediatePropagation(); return; }
        report('blocked', target.tagName.toLowerCase() + ' ' + source, source);
      }
      return;
    }
    var where = event.filename ? ' (' + event.filename + ':' + event.lineno + ':' + event.colno + ')' : '';
    var stack = event.error && event.error.stack ? '\n' + String(event.error.stack).slice(0, 4000) : '';
    var hidden = /^Script error\.?$/.test(String(event.message || '')) && !event.filename && !event.error;
    if (!hidden) return report('runtimeError', (event.message || 'Error') + where + stack);
    // React and others log the Error just before or just after it is thrown: wait a moment and attach what was logged.
    var thrownAt = performance.now();
    realSetTimeout(function () {
      var logged = lastLogged && Math.abs(lastLogged.at - thrownAt) < 3000 ? lastLogged.text : '';
      report('runtimeError', 'Script error. WebKit hides the message and stack of this error: it was thrown by a script of '
        + 'another origin or one without an address.' + (logged ? '\nThe application logged just then:\n' + logged
        : ' The application logged no Error object with it.'));
    }, 400);
  }, true);

  window.addEventListener('unhandledrejection', function (event) {
    var reason = event.reason;
    // WebKit's stack has no message line ("@http://host/app.js:7:89"), so an Error is described with its name and message first
    // (REQ-017: Fix data reads the message).
    report('runtimeError', 'Unhandled rejection: ' + (errorText(reason) || String((reason && (reason.stack || reason.message)) || reason).slice(0, 4000)));
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
  A.typedOn = null;
  document.addEventListener('input', function (event) { if (event.isTrusted) A.typedOn = location.pathname + location.search; }, true);

  // MARK: Electron preload bridge (REQ-016)

  // An Electron renderer runs here as a web page: its preload never runs, so the globals it exposes with
  // `contextBridge.exposeInMainWorld` would not exist. Each is a simulated bridge instead, a Proxy of any shape. A call
  // `window.<global>.<a>.<b>(...args)` is the request `<verb> http://electron.ipc/<global>/<a>/<b>[/<argument>…]` to MarkView,
  // answered by the simulated environment like any other API, and prepared when nothing answers it yet:
  // - the verb follows the method's first word: get, list, load, fetch, read, find, query, is, has, can → GET; delete,
  //   remove, clear → DELETE; update, patch → PATCH; save, set, put, reset, import → PUT; any other → POST. For
  //   `invoke(channel, …)`, `send` and `sendSync` it follows the channel's last part (`settings:get-document` → GET);
  // - string (up to 256 characters), number and boolean arguments are path segments, in order; undefined, null and empty
  //   strings are left out. One object, array or longer string is the JSON body; several are a JSON array;
  // - the header `x-markview-ipc-args` carries every argument as JSON, redacted and at most 4 KB, for the preparation;
  // - the call returns the promise of the answer's parsed JSON (undefined when it is empty); a status of 400 or more
  //   rejects it with the answer's message.
  // A call with a function argument subscribes: the callback gets what the simulated channel at the same address pushes,
  // and the call returns its unsubscribe function at once; `on`, `once` and `addListener` with a channel all listen at
  // `…/on/<channel>`. `off` and `remove…Listener(s)` unsubscribe. Reading a property
  // gives the bridge below it, never a value (`then` is undefined, so awaiting it does not hang).
  if (config.electron) {
    var IPC_ORIGIN = 'http://electron.ipc';
    var IPC_ARGS_HEADER = 'x-markview-ipc-args';
    var IPC_MAX_ARGS = 4096;
    var IPC_MAX_SEGMENT = 256;
    var IPC_CHANNEL_CALLS = { invoke: 1, send: 1, sendSync: 1, sendTo: 1, sendToHost: 1 };
    var IPC_UNSUBSCRIBE = /^(off|remove\w*Listeners?)$/;
    var IPC_UNSUBSCRIBE_CALLBACK = /^(unsubscribe|unlisten|unwatch)/i;
    // `ipcRenderer.on('chan', cb)` and its once and add… forms listen to the same channel.
    var IPC_LISTEN = /^(on|once|addListener|addEventListener|prependListener|prependOnceListener)$/;
    var IPC_NOT_CALLS = { then: 1, toJSON: 1, $$typeof: 1, nodeType: 1, asymmetricMatch: 1, '@@__IMMUTABLE_ITERABLE__@@': 1,
      '@@__IMMUTABLE_RECORD__@@': 1 };
    var ipcVerbs = Object.create(null);
    [['GET', 'get list load fetch read find query is has can'], ['DELETE', 'delete remove clear'], ['PATCH', 'update patch'],
      ['PUT', 'save set put reset import']].forEach(function (group) {
      group[1].split(' ').forEach(function (word) { ipcVerbs[word] = group[0]; });
    });
    // The same rule as StudioIPC.verb(of:) in Swift, which the application map uses.
    var ipcVerb = function (name) {
      var action = String(name).split(/[:/.]/).pop();
      var word = /^[^A-Za-z0-9]*([A-Za-z][a-z0-9]*)/.exec(action);
      return (word && ipcVerbs[word[1].toLowerCase()]) || 'POST';
    };
    var ipcScalar = function (value) {
      var type = typeof value;
      return (type === 'string' && value !== '' && value.length <= IPC_MAX_SEGMENT) || type === 'number' || type === 'boolean'
        || type === 'bigint';
    };
    // Foundation decodes %2F in a path, so a slash inside an argument is encoded twice and stays one segment.
    var ipcSegment = function (value) {
      var text = encodeURIComponent(String(value)).replace(/%2F/gi, '%252F');
      return text === '.' || text === '..' ? text.replace(/\./g, '%2E') : text;
    };
    var ipcRedaction = config.redaction || {};
    var ipcFields = (ipcRedaction.fields || []).map(function (field) { return String(field).toLowerCase().replace(/[_-]/g, ''); })
      .filter(function (field) { return field; });
    var ipcPatterns = (ipcRedaction.patterns || []).map(function (pattern) {
      try { return new RegExp(pattern, 'g'); } catch (error) { return null; }
    }).filter(function (pattern) { return pattern; });
    var ipcConfidential = function (name) {
      var key = String(name).toLowerCase().replace(/[_-]/g, '');
      return ipcFields.some(function (field) { return key.indexOf(field) >= 0; });
    };
    // The arguments as plain JSON values for the header: confidential fields and credential shapes redacted, functions named.
    var ipcPlain = function (value, depth, seen) {
      if (typeof value === 'function') return '[function]';
      if (value === undefined || typeof value === 'symbol') return null;
      if (typeof value === 'bigint') return String(value);
      if (typeof value === 'string') {
        return ipcPatterns.reduce(function (text, pattern) { return text.replace(pattern, '[redacted]'); }, value);
      }
      if (value === null || typeof value !== 'object') return value;
      if (depth > 8 || seen.indexOf(value) >= 0) return '[…]';
      seen.push(value);
      var out;
      try {
        if (Array.isArray(value)) {
          out = value.slice(0, 200).map(function (item) { return ipcPlain(item, depth + 1, seen); });
        } else if (value instanceof Date) {
          out = isNaN(value.getTime()) ? null : value.toISOString();
        } else {
          out = {};
          Object.keys(value).slice(0, 200).forEach(function (key) {
            out[key] = ipcConfidential(key) && value[key] != null ? '[redacted]' : ipcPlain(value[key], depth + 1, seen);
          });
        }
      } catch (error) { out = '[unreadable]'; }
      seen.pop();
      return out;
    };
    var ipcEncoder = new TextEncoder();
    var ipcArgsHeader = function (args) {
      var text = JSON.stringify(args.map(function (arg) { return ipcPlain(arg, 0, []); }));
      if (ipcEncoder.encode(text).length <= IPC_MAX_ARGS) return text;
      var cut = text.slice(0, IPC_MAX_ARGS - 3);
      while (cut && ipcEncoder.encode(cut).length > IPC_MAX_ARGS - 3) cut = cut.slice(0, Math.floor(cut.length * 0.9));
      return cut + '…';
    };
    var ipcError = function (label, message) {
      return new Error("Error invoking remote method '" + label + "': Error: " + message);
    };
    var ipcAnswer = function (reply, label) {
      var status = reply.status | 0;
      var text = reply.body == null ? '' : String(reply.body);
      var value;
      if (text !== '' && status !== 204 && status !== 205) {
        try { value = JSON.parse(text); } catch (error) { value = text; }
      }
      if (status < 400) return value;
      var message = typeof value === 'string' ? value : '';
      if (value && typeof value === 'object') {
        if (typeof value.message === 'string') message = value.message;
        else if (typeof value.error === 'string') message = value.error;
        else if (value.error && typeof value.error.message === 'string') message = value.error.message;
      }
      throw ipcError(label, message || 'the simulated main process answered ' + status);
    };
    var ipcAddress = function (path, args) {
      var segments = path.map(ipcSegment);
      args.forEach(function (arg) { if (ipcScalar(arg)) segments.push(ipcSegment(arg)); });
      return IPC_ORIGIN + '/' + segments.join('/');
    };

    var ipcRequest = function (path, args) {
      var name = path[path.length - 1];
      var channel = IPC_CHANNEL_CALLS[name] === 1 && typeof args[0] === 'string' ? args[0] : null;
      var label = channel || path.join('.');
      var values = args.filter(function (arg) {
        return arg !== undefined && arg !== null && arg !== '' && !ipcScalar(arg) && typeof arg !== 'function' && typeof arg !== 'symbol';
      });
      var body = null;
      try {
        if (values.length) body = JSON.stringify(values.length === 1 ? values[0] : values);
      } catch (error) {
        return Promise.reject(ipcError(label, 'An object could not be cloned.'));
      }
      var headers = {};
      if (body != null) headers['content-type'] = 'application/json';
      headers[IPC_ARGS_HEADER] = ipcArgsHeader(args);
      var url = ipcAddress(path, args);
      return ask({ method: ipcVerb(channel || name), url: url, headers: headers, body: body, transport: 'ipc' }).then(function (reply) {
        // The bridge has no real main process to pass a call to.
        if (reply.action !== 'respond') throw ipcError(label, 'MarkView UI Studio did not simulate ' + url);
        return deliver(reply).then(function () { return ipcAnswer(reply, label); });
      }, function (error) {
        throw ipcError(label, (error && error.message) || String(error));
      });
    };

    var ipcSubscriptions = [];
    var ipcStop = function (entry) {
      var index = ipcSubscriptions.indexOf(entry);
      if (index >= 0) ipcSubscriptions.splice(index, 1);
      var state = entry.state;
      if (state.readyState === state.closedState) return;
      var open = state.readyState === 1;
      state.readyState = state.closedState;
      delete channels[state.id];
      if (open) send({ kind: 'channel', action: 'close', id: state.id }).catch(function () {});
    };
    // A callback listens to the simulated channel at the call's address. An `ipcRenderer` listener gets the event first,
    // like Electron's; a bridge method's callback gets the value only. An error the callback throws surfaces as the page's.
    var ipcSubscribe = function (path, args, callback) {
      var name = path[path.length - 1];
      var entry = { parent: path.slice(0, -1).join('.'), scalars: args.filter(ipcScalar).map(String), callback: callback, state: null };
      var withEvent = path.indexOf('ipcRenderer') >= 0;
      var once = /^(once|prependOnce)/.test(name);
      var address = IPC_LISTEN.test(name) && typeof args[0] === 'string' ? path.slice(0, -1).concat('on') : path;
      var target = new EventTarget();
      target.onmessage = function (event) {
        var value = event.data;
        if (typeof value === 'string') {
          if (value === '') value = undefined;
          else try { value = JSON.parse(value); } catch (error) {}
        }
        if (once) ipcStop(entry);
        if (withEvent) callback.call(null, { sender: null, senderId: 0, ports: [] }, value); else callback.call(null, value);
      };
      entry.state = connect(target, ipcAddress(address, args), [], 'ipc');
      ipcSubscriptions.push(entry);
      return function unsubscribe() { ipcStop(entry); };
    };
    var ipcUnsubscribe = function (path, args) {
      var parent = path.slice(0, -1).join('.');
      var callback = args.filter(function (arg) { return typeof arg === 'function'; })[0];
      var scalars = args.filter(ipcScalar).map(String);
      ipcSubscriptions.slice().forEach(function (entry) {
        if (entry.parent !== parent || (callback && entry.callback !== callback)) return;
        if (scalars.some(function (scalar, index) { return entry.scalars[index] !== scalar; })) return;
        ipcStop(entry);
      });
      return undefined;
    };

    var ipcCall = function (path, args) {
      var name = path[path.length - 1];
      var callback = args.filter(function (arg) { return typeof arg === 'function'; })[0];
      if (IPC_UNSUBSCRIBE.test(name) || (callback && IPC_UNSUBSCRIBE_CALLBACK.test(name))) return ipcUnsubscribe(path, args);
      if (callback) return ipcSubscribe(path, args, callback);
      if (name === 'sendSync') {
        // A synchronous answer cannot wait for MarkView.
        report('electron', 'window.' + path.join('.') + '(' + (typeof args[0] === 'string' ? JSON.stringify(args[0]) : '') + ')');
        return undefined;
      }
      return ipcRequest(path, args);
    };

    var ipcBridges = Object.create(null);
    var ipcBridge = function (path) {
      var id = path.join('\u0000');
      if (ipcBridges[id]) return ipcBridges[id];
      var bridge = new Proxy(function () {}, {
        get: function (_, key) {
          if (key === Symbol.toPrimitive) return function () { return ''; };
          if (key === Symbol.iterator) return function* () {};
          if (typeof key === 'symbol' || IPC_NOT_CALLS[key] === 1) return undefined;
          if (key === 'toString' || key === 'valueOf') return function () { return ''; };
          return ipcBridge(path.concat(String(key)));
        },
        apply: function (_, self, args) { return ipcCall(path, Array.prototype.slice.call(args)); }
      });
      ipcBridges[id] = bridge;
      return bridge;
    };
    var names = config.electronGlobals && config.electronGlobals.length ? config.electronGlobals
      : ['electron', 'api', 'ipcRenderer', 'electronAPI', 'bridge', 'desktop'];
    names.forEach(function (name) { if (/^[A-Za-z_$][\w$]*$/.test(name) && !(name in window)) window[name] = ipcBridge([name]); });
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
      if (A.host && (el === A.host || A.host.contains(el))) continue;
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
})(window.__markviewStudioParts, __MARKVIEW_STUDIO_CONFIG__);
