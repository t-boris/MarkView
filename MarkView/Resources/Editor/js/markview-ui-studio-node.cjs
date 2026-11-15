// MarkView UI Studio Node preload. MarkView starts a project's development server with
// `NODE_OPTIONS=--require "<this file>"` and `MARKVIEW_STUDIO_CLOCK=<absolute path of a JSON file>`, so every Node process
// of the server (and every child Node process, which inherits NODE_OPTIONS) renders with the same test clock, time zone
// and locale as the page runtime (markview-ui-studio.js) gives the browser page. Without it the server renders with the
// real clock and the client with the test clock, and React reports a hydration mismatch.
//
// The clock file, written by MarkView and rewritten at any time while the server runs:
//   { "testTime": 1768478400000, "anchor": 1793750400000, "timeZone": "America/Chicago", "locale": "en-US" }
// - testTime: epoch ms of the test time; anchor: the real epoch ms at which the test clock showed testTime, so
//   test now = testTime + (real now - anchor). testTime may be null or absent (the clock stays real); when it is a
//   number, anchor must be one too.
// - timeZone and locale may be null or absent (left as they are). A value Intl does not accept counts as absent.
//
// The test clock and locale apply only while a server handles a request: from the moment an http, https or http2
// (compatibility API) server emits 'request' through everything that call starts, including after `await`, in timers
// and in the callbacks of a streamed response (an AsyncLocalStorage). Everything else keeps the real clock and the
// process's own locale: file watchers that compare file times with Date.now() (on a clock behind the files, webpack's
// watchpack reports unchanged files as changed, and webpack rebuilds), caches, logs, and npm, tsc and other tools,
// which load this preload through NODE_OPTIONS too but serve no requests.
//
// What it does once the file parses:
// - Date: the global Date is replaced by a function that shares Date.prototype; inside a request Date.now(),
//   `new Date()` and `Date()` give test now. `new Date(x)`, Date.UTC, Date.parse, instanceof (also for dates Node itself
//   creates) and subclasses keep working everywhere. performance.now(), process.hrtime and timers stay on the real clock.
// - Time zone: process.env.TZ is set (Node re-reads it on assignment) and restored when a later file drops the zone. It
//   is process-wide, outside requests too: a zone cannot be scoped to a request, and it does not change epoch times, so
//   comparisons of file times are unaffected.
// - Locale: inside a request the Intl constructors, the toLocale* methods, String.prototype.localeCompare and
//   navigator.language (Node 21+) use the scenario locale when the caller passes no locale; an explicit locale is
//   respected.
// - Cookies: the browser expires cookies by the real clock, while a request handler computes `Expires` from the test
//   clock, so the Expires attribute of a Set-Cookie header set inside a request (http and the http2 compatibility API)
//   is moved back to real time. Max-Age and everything else are left untouched, and so is a header set outside a
//   request, whose date came from the real clock.
//
// Limits of the request scope: work a request starts keeps its context for good (a timer, a watcher or an on-demand
// compilation that a request triggers sees the test clock, so a watch started from a request can still report
// unchanged files), and a value made outside a request (a formatter or a date cached at startup) keeps the real clock
// and locale when a request uses it later. Requests to the development server's own endpoints (lazy compilation, hot
// updates, hot-reload channels) never enter the scope, since the compilations they start would rebuild without end.
//
// It never throws and never keeps a process alive: a missing, half-written or invalid file keeps the last good
// configuration, and without MARKVIEW_STUDIO_CLOCK (or a file that never parses) it changes nothing at all.
// `convertSetCookie(value, offsetMs)` is exported for tests. Requiring it twice (also through a different path) is
// harmless: the first copy registers itself under a global symbol and later copies return it.
'use strict';

const INSTALLED = Symbol.for('markview.uiStudio.nodeClock');
const CLOCK_ENV = 'MARKVIEW_STUDIO_CLOCK';
// The TZ the server started with, recorded for child processes: they inherit the zone this process applied and must
// restore the original one, not the inherited one, when the scenario drops its zone.
const ORIGINAL_TZ_ENV = 'MARKVIEW_STUDIO_ORIGINAL_TZ';
const MAX_FILE_BYTES = 64 * 1024;
const MAX_TIME = 8.64e15;

// Captured before anything is replaced; Node's own internals use their own copies (primordials) anyway.
const RealDate = Date;
const realDateNow = Date.now;
const RealDateTimeFormat = Intl.DateTimeFormat;
const realGetCanonicalLocales = Intl.getCanonicalLocales;

const state = { offset: 0, locale: null };

// MARK: Request context

let requestContext = null;
function inRequest() {
  return requestContext !== null && requestContext.getStore() === true;
}

// The development server's own endpoints (BUG-081): a bundler's lazy compilation, hot updates and hot-reload channels. A
// compilation they start must keep the real clock, or its file watcher sees every file as changed and rebuilds without end;
// they never render the application, so the test clock has nothing to do there.
const DEV_SERVER_PREFIXES = ['/lazy-compilation-using-', '/__webpack_hmr', '/__webpack_dev_server__', '/webpack-dev-server',
  '/sockjs-node', '/__rspack', '/rsbuild-hmr', '/__rsbuild', '/_next/webpack-hmr', '/__parcel', '/@vite/'];
function isDevServerRequest(request) {
  try {
    const url = request && typeof request.url === 'string' ? request.url : '';
    const path = url.split('?')[0];
    if (path.indexOf('.hot-update.') >= 0) return true;
    for (let i = 0; i < DEV_SERVER_PREFIXES.length; i++) {
      if (path.indexOf(DEV_SERVER_PREFIXES[i]) === 0) return true;
    }
  } catch (error) {}
  return false;
}

let contextInstalled = false;
function installRequestContext() {
  if (contextInstalled) return;
  contextInstalled = true;
  try {
    const AsyncLocalStorage = require('async_hooks').AsyncLocalStorage;
    const context = new AsyncLocalStorage();
    // http.Server, https.Server (through tls.Server) and the http2 servers all inherit emit from net.Server.
    replaceMethod(require('net').Server.prototype, 'emit', function (real) {
      return function (event) {
        if (event !== 'request' || isDevServerRequest(arguments[1])) return real.apply(this, arguments);
        const self = this;
        const args = arguments;
        return context.run(true, function () { return real.apply(self, args); });
      };
    });
    requestContext = context;
  } catch (error) {}
}

// MARK: Cookies

function isSetCookie(name) {
  return typeof name === 'string' && name.length === 10 && name.toLowerCase() === 'set-cookie';
}

function convertCookie(cookie, offsetMs) {
  if (typeof cookie !== 'string') return cookie;
  const parts = cookie.split(';');
  let changed = false;
  // parts[0] is name=value: a cookie called "expires" is not an attribute.
  for (let i = 1; i < parts.length; i++) {
    const match = /^(\s*expires\s*=\s*)(.*?)(\s*)$/i.exec(parts[i]);
    if (!match) continue;
    const testMs = RealDate.parse(match[2]);
    if (!isFinite(testMs)) continue;
    // Before 1970 the cookie is expired by both clocks; the epoch keeps a date every browser parses.
    const realMs = Math.max(0, testMs - offsetMs);
    const text = new RealDate(realMs).toUTCString();
    if (text === 'Invalid Date') continue;
    parts[i] = match[1] + text + match[3];
    changed = true;
  }
  return changed ? parts.join(';') : cookie;
}

// Moves the Expires attribute of a Set-Cookie value (a string or an array of strings) from the test clock to the real
// one: real = expires - offsetMs, where offsetMs = test now - real now. Returns the value itself when nothing changes
// and never modifies the caller's array.
function convertSetCookie(value, offsetMs) {
  try {
    if (typeof offsetMs !== 'number' || !isFinite(offsetMs) || offsetMs === 0) return value;
    if (typeof value === 'string') return convertCookie(value, offsetMs);
    if (!Array.isArray(value)) return value;
    let changed = false;
    const converted = value.map(function (cookie) {
      const result = convertCookie(cookie, offsetMs);
      if (result !== cookie) changed = true;
      return result;
    });
    return changed ? converted : value;
  } catch (error) {
    return value;
  }
}

// writeHead takes a headers object, an array of [name, value] pairs or a flat [name, value, name, value…] array.
function convertHeaders(headers, offsetMs) {
  try {
    if (!headers || typeof headers !== 'object' || !offsetMs) return headers;
    let copy = null;
    if (Array.isArray(headers)) {
      if (headers.length && Array.isArray(headers[0])) {
        headers.forEach(function (entry, index) {
          if (!Array.isArray(entry) || !isSetCookie(entry[0])) return;
          const value = convertSetCookie(entry[1], offsetMs);
          if (value === entry[1]) return;
          copy = copy || headers.slice();
          copy[index] = entry.slice();
          copy[index][1] = value;
        });
      } else {
        for (let i = 0; i + 1 < headers.length; i += 2) {
          if (!isSetCookie(headers[i])) continue;
          const value = convertSetCookie(headers[i + 1], offsetMs);
          if (value === headers[i + 1]) continue;
          copy = copy || headers.slice();
          copy[i + 1] = value;
        }
      }
      return copy || headers;
    }
    Object.keys(headers).forEach(function (name) {
      if (!isSetCookie(name)) return;
      const value = convertSetCookie(headers[name], offsetMs);
      if (value === headers[name]) return;
      copy = copy || Object.assign(Object.create(Object.getPrototypeOf(headers)), headers);
      copy[name] = value;
    });
    return copy || headers;
  } catch (error) {
    return headers;
  }
}

const api = { convertSetCookie: convertSetCookie };

// MARK: Hooks

function sameShape(wrapper, real) {
  try {
    Object.defineProperty(wrapper, 'name', { value: real.name, configurable: true });
    Object.defineProperty(wrapper, 'length', { value: real.length, configurable: true });
  } catch (error) {}
  return wrapper;
}

function replaceMethod(owner, name, makeWrapper) {
  try {
    const real = owner && owner[name];
    if (typeof real !== 'function') return;
    owner[name] = sameShape(makeWrapper(real), real);
  } catch (error) {}
}

// Test now inside a request, real now everywhere else.
function studioNow() {
  return state.offset && inRequest() ? Math.floor(realDateNow() + state.offset) : realDateNow();
}

let clockInstalled = false;
function installClock() {
  if (clockInstalled) return;
  clockInstalled = true;
  installRequestContext();
  try {
    const StudioDate = function Date(year, monthIndex, day, hours, minutes, seconds, ms) {
      if (!new.target) return new RealDate(studioNow()).toString();
      // Reflect.construct keeps the prototype of a subclass (`class D extends Date`).
      if (arguments.length === 0) return Reflect.construct(RealDate, [studioNow()], new.target);
      return Reflect.construct(RealDate, arguments, new.target);
    };
    Reflect.ownKeys(RealDate).forEach(function (key) {
      if (key === 'length' || key === 'name' || key === 'prototype') return;
      Object.defineProperty(StudioDate, key, Object.getOwnPropertyDescriptor(RealDate, key));
    });
    // A method is not a constructor, like the real Date.now.
    Object.defineProperty(StudioDate, 'now', { value: { now() { return studioNow(); } }.now, writable: true, configurable: true });
    // Shared with the real Date, so dates made anywhere (fs.Stats, structuredClone…) stay `instanceof Date`.
    Object.defineProperty(StudioDate, 'prototype', { value: RealDate.prototype, writable: false });
    globalThis.Date = StudioDate;
    RealDate.prototype.constructor = StudioDate;
  } catch (error) {}
  installCookieHooks();
}

// Node stores headers through its own methods: writeHead calls setHeader or appendHeader for its headers argument, and
// appendHeader calls setHeader for a header that is not set yet. The value is converted once, by the outermost call.
let hookDepth = 0;
function callReal(real, self, args) {
  hookDepth++;
  try {
    return real.apply(self, args);
  } finally {
    hookDepth--;
  }
}

// Only a header set inside a request carries a test-clock date; elsewhere the date came from the real clock.
function cookieOffset() {
  return !hookDepth && state.offset && inRequest() ? state.offset : 0;
}

function hookResponse(proto) {
  ['setHeader', 'appendHeader'].forEach(function (name) {
    replaceMethod(proto, name, function (real) {
      return function (headerName, value) {
        let args = arguments;
        const offset = cookieOffset();
        if (offset && isSetCookie(headerName)) {
          args = Array.prototype.slice.call(arguments);
          args[1] = convertSetCookie(value, offset);
        }
        return callReal(real, this, args);
      };
    });
  });
  replaceMethod(proto, 'writeHead', function (real) {
    return function (statusCode, reason, headers) {
      let args = arguments;
      const offset = cookieOffset();
      if (offset) {
        // writeHead(status, reasonPhrase, headers) or writeHead(status, headers). Node versions differ on which
        // argument wins when both of the last two are objects; converting a copy of an ignored one is harmless.
        for (let index = typeof reason === 'string' ? 2 : 1; index <= 2; index++) {
          const converted = convertHeaders(args[index], offset);
          if (converted === args[index]) continue;
          if (args === arguments) args = Array.prototype.slice.call(arguments);
          args[index] = converted;
        }
      }
      return callReal(real, this, args);
    };
  });
}

function installCookieHooks() {
  try { hookResponse(require('http').ServerResponse.prototype); } catch (error) {}
  // The http2 compatibility API has a response class of its own (https development servers, Vite among them).
  try { hookResponse(require('http2').Http2ServerResponse.prototype); } catch (error) {}
}

// The scenario locale inside a request, null (the process's own default) everywhere else.
function studioLocale() {
  return state.locale && inRequest() ? state.locale : null;
}

function localeOr(locales) {
  return locales === undefined ? studioLocale() || undefined : locales;
}

let localeInstalled = false;
function installLocale() {
  if (localeInstalled) return;
  localeInstalled = true;
  installRequestContext();
  ['DateTimeFormat', 'NumberFormat', 'Collator', 'PluralRules', 'RelativeTimeFormat', 'ListFormat'].forEach(function (name) {
    try {
      const Real = Intl[name];
      if (typeof Real !== 'function') return;
      const Wrapped = function (locales, options) {
        // Called without `new`, the real constructor decides: DateTimeFormat, NumberFormat and Collator return an
        // instance, the others throw.
        if (!new.target) return Real.call(this, localeOr(locales), options);
        return Reflect.construct(Real, [localeOr(locales), options], new.target);
      };
      Reflect.ownKeys(Real).forEach(function (key) {
        if (key === 'length' || key === 'name' || key === 'prototype') return;
        Object.defineProperty(Wrapped, key, Object.getOwnPropertyDescriptor(Real, key));
      });
      Object.defineProperty(Wrapped, 'prototype', { value: Real.prototype, writable: false });
      sameShape(Wrapped, Real);
      Real.prototype.constructor = Wrapped;
      Intl[name] = Wrapped;
    } catch (error) {}
  });
  ['toLocaleString', 'toLocaleDateString', 'toLocaleTimeString'].forEach(function (name) {
    replaceMethod(RealDate.prototype, name, function (real) {
      return function (locales, options) { return real.call(this, localeOr(locales), options); };
    });
  });
  replaceMethod(Number.prototype, 'toLocaleString', function (real) {
    return function (locales, options) { return real.call(this, localeOr(locales), options); };
  });
  replaceMethod(String.prototype, 'localeCompare', function (real) {
    return function (that, locales, options) { return real.call(this, that, localeOr(locales), options); };
  });
  try {
    // Node 21+ has navigator.language, read from the process's default locale.
    const navigator = globalThis.navigator;
    const proto = navigator && Object.getPrototypeOf(navigator);
    const language = proto && Object.getOwnPropertyDescriptor(proto, 'language');
    const languages = proto && Object.getOwnPropertyDescriptor(proto, 'languages');
    if (language && language.get && language.configurable) {
      Object.defineProperty(proto, 'language', {
        get: function () { return studioLocale() || language.get.call(this); },
        enumerable: language.enumerable, configurable: true
      });
    }
    if (languages && languages.get && languages.configurable) {
      Object.defineProperty(proto, 'languages', {
        get: function () { const locale = studioLocale(); return locale ? [locale] : languages.get.call(this); },
        enumerable: languages.enumerable, configurable: true
      });
    }
  } catch (error) {}
}

// MARK: Time zone

let originalZone;
let zoneApplied = false;
function readOriginalZone() {
  if (Object.prototype.hasOwnProperty.call(process.env, ORIGINAL_TZ_ENV)) {
    // A parent process applied a zone: the TZ this process inherited is that zone, not the server's own.
    zoneApplied = true;
    try {
      const recorded = JSON.parse(process.env[ORIGINAL_TZ_ENV]);
      originalZone = typeof recorded === 'string' ? recorded : undefined;
      return;
    } catch (error) {}
  }
  originalZone = process.env.TZ;
}

function applyZone(zone) {
  if (zone) {
    if (!Object.prototype.hasOwnProperty.call(process.env, ORIGINAL_TZ_ENV)) {
      process.env[ORIGINAL_TZ_ENV] = JSON.stringify(originalZone === undefined ? null : originalZone);
    }
    if (process.env.TZ !== zone) process.env.TZ = zone;
    zoneApplied = true;
  } else if (zoneApplied) {
    if (originalZone === undefined) {
      if (process.env.TZ !== undefined) delete process.env.TZ;
    } else if (process.env.TZ !== originalZone) {
      process.env.TZ = originalZone;
    }
    zoneApplied = false;
  }
}

// MARK: Clock file

function validTime(value) {
  return typeof value === 'number' && isFinite(value) && Math.abs(value) <= MAX_TIME;
}

function validZone(value) {
  if (typeof value !== 'string' || !value || value.length > 128) return null;
  try {
    new RealDateTimeFormat('en-US', { timeZone: value });
    return value;
  } catch (error) {
    return null;
  }
}

function validLocale(value) {
  if (typeof value !== 'string' || !value || value.length > 128) return null;
  try {
    return realGetCanonicalLocales.call(Intl, value)[0] || null;
  } catch (error) {
    return null;
  }
}

// Returns null for anything but a valid clock file, so the last good configuration stays.
function parseConfig(text) {
  const raw = JSON.parse(text);
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  let offset = null;
  if (raw.testTime !== undefined && raw.testTime !== null) {
    if (!validTime(raw.testTime) || !validTime(raw.anchor)) return null;
    offset = raw.testTime - raw.anchor;
  }
  return { offset: offset, timeZone: validZone(raw.timeZone), locale: validLocale(raw.locale) };
}

function applyConfig(config) {
  if (config.offset !== null) installClock();
  state.offset = config.offset || 0;
  if (config.locale) installLocale();
  state.locale = config.locale;
  try { applyZone(config.timeZone); } catch (error) {}
}

function start() {
  const file = process.env[CLOCK_ENV];
  // Absolute only: child processes of the server run in other folders.
  if (typeof file !== 'string' || !require('path').isAbsolute(file)) return;
  const fs = require('fs');
  const statSync = fs.statSync;
  const readFileSync = fs.readFileSync;
  let lastText = null;
  readOriginalZone();
  function load() {
    try {
      if (statSync(file).size > MAX_FILE_BYTES) return;
      const text = readFileSync(file, 'utf8');
      if (text === lastText) return;
      const config = parseConfig(text);
      if (!config) return;
      lastText = text;
      applyConfig(config);
    } catch (error) {}
  }
  load();
  // Polling a stat never keeps the process alive (persistent: false) and survives the file being replaced.
  fs.watchFile(file, { interval: 250, persistent: false }, load);
}

module.exports = (function () {
  try {
    if (globalThis[INSTALLED]) return globalThis[INSTALLED];
    Object.defineProperty(globalThis, INSTALLED, { value: api });
  } catch (error) {
    return api;
  }
  try { start(); } catch (error) {}
  return api;
})();
