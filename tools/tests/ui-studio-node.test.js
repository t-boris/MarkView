// Checks UI Studio's Node preload (MarkView/Resources/Editor/vendor/js/markview-ui-studio-node.cjs) the way a
// development server runs it: every scenario is a separate node process started with NODE_OPTIONS=--require and
// MARKVIEW_STUDIO_CLOCK, while this driver keeps the real clock. The test clock and locale belong to request handlers
// only, so most scenarios serve requests (often to themselves) and compare what a handler sees with what code outside
// any request sees. Run with tools/tests/ui-studio-node-tests.sh.
//   node tools/tests/ui-studio-node.test.js <preload.cjs> <temporary folder>
'use strict';
const fs = require('fs');
const path = require('path');
const http = require('http');
const https = require('https');
const http2 = require('http2');
const readline = require('readline');
const { spawn, spawnSync } = require('child_process');

const preload = path.resolve(process.argv[2]);
const work = path.resolve(process.argv[3]);
// A second copy under a folder with a space: NODE_OPTIONS must quote it, and loading both copies must be harmless.
const copyDir = path.join(work, 'Mark View');
fs.mkdirSync(copyDir, { recursive: true });
const copy = path.join(copyDir, path.basename(preload));
fs.copyFileSync(preload, copy);
const clock = path.join(work, 'clock.json');
const childScript = path.join(work, 'child.js');

const DAY = 86400000;
const TEST_TIME = Date.UTC(2024, 1, 29, 12); // a leap day, in another year than the real clock
const SLACK = 50;
const REAL_NUMBER = '1,234.5'; // the scenario processes run with LC_ALL=en_US.UTF-8
const TEST_NUMBER = '1.234,5'; // de-DE

let failures = 0;
function check(name, ok, detail) {
  if (ok) {
    console.log('ok   ' + name);
  } else {
    failures++;
    console.log('FAIL ' + name + (detail === undefined ? '' : ' got ' + JSON.stringify(detail)));
  }
}

let anchor = 0;
function writeClock(config) {
  fs.writeFileSync(clock, typeof config === 'string' ? config : JSON.stringify(config));
}
function startClock(config) {
  anchor = Date.now();
  writeClock(Object.assign({ testTime: TEST_TIME, anchor: anchor }, config));
}
// The test clock of a request handled between the real times t0 and t1.
function testRange(t0, t1, testTime) {
  const start = testTime === undefined ? TEST_TIME : testTime;
  return [start + (t0 - anchor) - SLACK, start + (t1 - anchor) + SLACK];
}
function realRange(t0, t1) {
  return [t0 - SLACK, t1 + SLACK];
}
function within(value, range) {
  return typeof value === 'number' && value >= range[0] && value <= range[1];
}

// The scenario processes run in a server's surroundings: another time zone than the scenario's and a known locale.
function baseEnv(extra) {
  const env = Object.assign({}, process.env);
  delete env.NODE_OPTIONS;
  delete env.MARKVIEW_STUDIO_CLOCK;
  delete env.MARKVIEW_STUDIO_ORIGINAL_TZ;
  env.TZ = 'Asia/Tokyo';
  env.LC_ALL = 'en_US.UTF-8';
  env.LANG = 'en_US.UTF-8';
  env.TEST_PRELOAD = preload;
  env.TEST_COPY = copy;
  env.TEST_CHILD = childScript;
  return Object.assign(env, extra);
}
function studioEnv(preloadPath, extra) {
  return baseEnv(Object.assign({ NODE_OPTIONS: '--require "' + preloadPath + '"', MARKVIEW_STUDIO_CLOCK: clock }, extra));
}

function runSync(scenario, env) {
  const result = spawnSync(process.execPath, ['-e', '(' + scenario + ')()'], { env: env, encoding: 'utf8', timeout: 20000 });
  const lines = String(result.stdout || '').trim().split('\n');
  try {
    return JSON.parse(lines[lines.length - 1]);
  } catch (error) {
    return { error: String(result.stdout) + String(result.stderr) };
  }
}

// A long-running scenario process: its JSON lines are collected and awaited.
function runLive(scenario, env) {
  const child = spawn(process.execPath, ['-e', '(' + scenario + ')()'], { env: env, stdio: ['ignore', 'pipe', 'pipe'] });
  const lines = [];
  const waiters = [];
  let stderr = '';
  child.stderr.on('data', function (chunk) { stderr += chunk; });
  readline.createInterface({ input: child.stdout }).on('line', function (text) {
    let line;
    try { line = JSON.parse(text); } catch (error) { return; }
    line.receivedAt = Date.now();
    lines.push(line);
    waiters.slice().forEach(function (waiter) { if (waiter.test(line)) waiter.done(line); });
  });
  return {
    lines: lines,
    stderr: function () { return stderr; },
    waitFor: function (test, timeoutMs) {
      const found = lines.find(test);
      if (found) return Promise.resolve(found);
      return new Promise(function (resolve) {
        const waiter = { test: test, done: null };
        const timer = setTimeout(function () { finish(null); }, timeoutMs);
        function finish(line) {
          clearTimeout(timer);
          waiters.splice(waiters.indexOf(waiter), 1);
          resolve(line);
        }
        waiter.done = finish;
        waiters.push(waiter);
      });
    },
    stop: function () { child.kill('SIGKILL'); }
  };
}

function sleep(ms) { return new Promise(function (resolve) { setTimeout(resolve, ms); }); }

function collectBody(response, resolve) {
  let body = '';
  response.setEncoding('utf8');
  response.on('data', function (chunk) { body += chunk; });
  response.on('end', function () {
    let json = null;
    try { json = JSON.parse(body); } catch (error) {}
    resolve({ cookies: response.headers['set-cookie'] || [], test: response.headers['x-test'], json: json });
  });
}

function get(port, route) {
  return new Promise(function (resolve) {
    http.get({ host: '127.0.0.1', port: port, path: route }, function (response) { collectBody(response, resolve); })
      .on('error', function (error) { resolve({ cookies: [], error: String(error) }); });
  });
}

// Whether every Set-Cookie with an Expires attribute expires one day after the real now.
function expiresTomorrow(cookies) {
  const expiring = cookies.filter(function (cookie) { return /expires=/i.test(cookie); });
  const realExpiry = Date.now() + DAY;
  return expiring.length > 0 && expiring.every(function (cookie) {
    return Math.abs(Date.parse(/expires=([^;]*)/i.exec(cookie)[1]) - realExpiry) < 5000;
  });
}

// MARK: Scenarios (each runs in its own node process; no closures)

function activeScenario() {
  const http = require('http');
  const fs = require('fs');
  const { Readable } = require('stream');
  function collect() {
    const out = {};
    out.now = Date.now();
    out.newDate = new Date().getTime();
    out.year = new Date().getFullYear();
    out.dateCall = Date();
    out.dateCallType = typeof Date('ignored');
    out.epoch = new Date(0).toISOString();
    out.parts = new Date(2020, 0, 1, 8).getHours() + '/' + new Date(2020, 0, 1).getFullYear();
    out.isoString = new Date('2020-01-01T00:00:00Z').getTime();
    out.utc = Date.UTC(2020, 0, 1);
    out.parse = Date.parse('2020-01-01T00:00:00Z');
    out.instance = new Date() instanceof Date;
    out.tag = Object.prototype.toString.call(new Date());
    out.ctor = new Date().constructor === Date;
    out.shape = Date.name + '/' + Date.length + '/' + (Object.getPrototypeOf(new Date()) === Date.prototype);
    out.nodeDate = fs.statSync(process.execPath).mtime instanceof Date;
    class Later extends Date {}
    const later = new Later();
    out.subclass = later instanceof Later && later instanceof Date && Math.abs(later.getTime() - Date.now()) < 5000;
    out.performance = performance.timeOrigin + performance.now();
    out.tz = process.env.TZ;
    out.hours = new Date(Date.UTC(2026, 0, 15, 12)).getHours();
    out.intlZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    out.number = (1234.5).toLocaleString();
    out.numberExplicit = (1234.5).toLocaleString('en-US');
    out.numberFormat = new Intl.NumberFormat().format(1234.5) + ' ' + Intl.NumberFormat().format(1234.5);
    out.numberFormatExplicit = new Intl.NumberFormat('en-US').format(1234.5);
    out.intlLocale = Intl.DateTimeFormat().resolvedOptions().locale;
    out.intlLocaleExplicit = new Intl.DateTimeFormat('en-US').resolvedOptions().locale;
    out.dateLocale = new Date(Date.UTC(2026, 0, 15, 12)).toLocaleDateString();
    out.dateLocaleExplicit = new Date(Date.UTC(2026, 0, 15, 12)).toLocaleDateString('en-US');
    out.timeLocale = new Date(Date.UTC(2026, 0, 15, 12)).toLocaleTimeString();
    out.compare = 'ä'.localeCompare('z') + '/' + 'ä'.localeCompare('z', 'sv');
    // ICU resolves some services to the language alone ("de"): compare with an explicit de-DE.
    out.collator = new Intl.Collator().resolvedOptions().locale === new Intl.Collator('de-DE').resolvedOptions().locale;
    out.list = new Intl.ListFormat().format(['a', 'b']);
    out.relative = new Intl.RelativeTimeFormat().format(1, 'day');
    out.plural = new Intl.PluralRules().resolvedOptions().locale === new Intl.PluralRules('de-DE').resolvedOptions().locale &&
      new Intl.PluralRules().resolvedOptions().locale !== new Intl.PluralRules('en-US').resolvedOptions().locale;
    out.intlShape = (new Intl.NumberFormat() instanceof Intl.NumberFormat) + '/' + Intl.NumberFormat.name + '/' +
      Intl.NumberFormat.supportedLocalesOf(['de-DE']).length;
    out.navigator = typeof navigator === 'undefined' ? null : navigator.language + ',' + navigator.languages.join(',');
    return out;
  }
  const result = { outside: collect(), ticks: [], inside: null };
  // A timer started before the server keeps running while a request is handled.
  const ticker = setInterval(function () {
    result.ticks.push({ now: Date.now(), number: (1234.5).toLocaleString(), year: new Date().getFullYear() });
  }, 10);
  const server = http.createServer(async function (req, res) {
    const inside = collect();
    result.inside = inside;
    await new Promise(function (resolve) { setTimeout(resolve, 60); });
    inside.afterAwait = { now: Date.now(), number: (1234.5).toLocaleString() };
    inside.inTimeout = await new Promise(function (resolve) {
      setTimeout(function () { resolve({ now: Date.now(), number: (1234.5).toLocaleString() }); }, 5);
    });
    // A second copy under another path, as a child process may load it through both NODE_OPTIONS and execArgv.
    const first = require(process.env.TEST_PRELOAD);
    const second = require(process.env.TEST_COPY);
    inside.sameApi = first === second && typeof second.convertSetCookie === 'function';
    inside.nowAfterSecond = Date.now();
    // A streamed response large enough to wait for the socket to drain: later reads run from its callbacks.
    inside.streamed = [];
    let chunks = 0;
    const big = 'x'.repeat(65536);
    new Readable({
      read: function () {
        inside.streamed.push(Date.now());
        this.push(chunks++ < 64 ? big : null);
      }
    }).pipe(res);
  });
  server.listen(0, '127.0.0.1', function () {
    http.get({ host: '127.0.0.1', port: server.address().port }, function (response) {
      response.resume();
      response.on('end', function () {
        clearInterval(ticker);
        server.close();
        result.after = { now: Date.now(), number: (1234.5).toLocaleString() };
        console.log(JSON.stringify(result));
      });
    });
  });
}

function inactiveScenario() {
  const native = function (fn) { return /\[native code\]/.test(Function.prototype.toString.call(fn)); };
  const own = function (object, key) { return Object.prototype.hasOwnProperty.call(object, key); };
  console.log(JSON.stringify({
    now: Date.now(),
    nativeDate: native(Date) && native(Intl.NumberFormat) && native(Number.prototype.toLocaleString),
    hooked: own(require('http').ServerResponse.prototype, 'setHeader') || own(require('net').Server.prototype, 'emit'),
    number: (1234.5).toLocaleString(),
    tz: process.env.TZ,
    hours: new Date(Date.UTC(2026, 0, 15, 12)).getHours()
  }));
}

function liveScenario() {
  const http = require('http');
  const sample = function () {
    return {
      now: Date.now(), year: new Date().getFullYear(), tz: process.env.TZ === undefined ? null : process.env.TZ,
      hours: new Date(Date.UTC(2026, 0, 15, 12)).getHours(), number: (1234.5).toLocaleString()
    };
  };
  const server = http.createServer(function (req, res) { res.end(JSON.stringify(sample())); });
  server.listen(0, '127.0.0.1', function () {
    // Requests to itself over a kept-alive connection, every 50 ms.
    const poll = function () {
      http.get({ host: '127.0.0.1', port: server.address().port }, function (response) {
        let body = '';
        response.on('data', function (chunk) { body += chunk; });
        response.on('end', function () {
          console.log(JSON.stringify({ inside: JSON.parse(body), outside: sample() }));
          setTimeout(poll, 50);
        });
      });
    };
    poll();
  });
}

function workerScenario() {
  const { Worker } = require('worker_threads');
  const code = [
    'const http = require("http");',
    'const { parentPort } = require("worker_threads");',
    'const outside = { now: Date.now(), number: (1234.5).toLocaleString() };',
    'const server = http.createServer((req, res) => res.end(JSON.stringify({ now: Date.now(), number: (1234.5).toLocaleString() })));',
    'server.listen(0, "127.0.0.1", () => http.get({ host: "127.0.0.1", port: server.address().port }, (response) => {',
    '  let body = ""; response.on("data", (chunk) => { body += chunk; });',
    '  response.on("end", () => { server.close(); parentPort.postMessage({ outside, inside: JSON.parse(body) }); });',
    '}));'
  ].join('\n');
  const worker = new Worker(code, { eval: true });
  worker.on('message', function (message) { console.log(JSON.stringify(message)); worker.terminate(); });
}

function serverScenario() {
  const http = require('http');
  const expires = function () { return new Date(Date.now() + 86400000).toUTCString(); };
  // Responses finished by a timer started before the server: outside any request, on the real clock.
  const later = [];
  setInterval(function () {
    const res = later.shift();
    if (!res) return;
    res.setHeader('Set-Cookie', 'z=9; Expires=' + expires());
    res.end('ok');
  }, 20);
  const server = http.createServer(function (req, res) {
    switch (req.url) {
      case '/set':
        res.setHeader('Set-Cookie', ['a=1; Expires=' + expires() + '; Max-Age=86400; Path=/', 'b=2; Path=/']);
        break;
      case '/head':
        res.writeHead(200, { 'set-cookie': 'c=3; Expires=' + expires() + '; Max-Age=60', 'X-Test': 'y' });
        break;
      case '/pairs':
        res.writeHead(200, 'OK', [['Set-Cookie', 'd=4; expires=' + expires() + '; HttpOnly'], ['X-Test', 'y']]);
        break;
      case '/raw':
        res.writeHead(200, ['Set-Cookie', 'e=5; Expires=' + expires(), 'X-Test', 'y']);
        break;
      case '/mixed':
        // setHeader before writeHead makes Node store writeHead's headers through setHeader: converted once only.
        res.setHeader('X-Test', 'y');
        res.writeHead(200, { 'Set-Cookie': ['f=6; Expires=' + expires()] });
        break;
      case '/append':
        // appendHeader calls setHeader for a header that is not set yet: converted once only.
        if (typeof res.appendHeader === 'function') {
          res.appendHeader('set-cookie', 'g=7; Expires=' + expires());
          res.appendHeader('Set-Cookie', ['h=8; Expires=' + expires()]);
        }
        break;
      case '/later':
        setTimeout(function () {
          res.setHeader('Set-Cookie', 'i=10; Expires=' + expires());
          res.end('ok');
        }, 10);
        return;
      case '/outside':
        later.push(res);
        return;
    }
    res.end('ok');
  });
  server.listen(0, '127.0.0.1', function () { console.log(JSON.stringify({ port: server.address().port })); });
}

function secureScenario() {
  const fs = require('fs');
  const https = require('https');
  const http2 = require('http2');
  const options = { key: fs.readFileSync(process.env.TEST_KEY), cert: fs.readFileSync(process.env.TEST_CERT) };
  const handler = function (req, res) {
    res.setHeader('Set-Cookie', 's=1; Expires=' + new Date(Date.now() + 86400000).toUTCString());
    res.end(JSON.stringify({ now: Date.now(), number: (1234.5).toLocaleString() }));
  };
  const secure = https.createServer(options, handler);
  const compat = http2.createSecureServer(options, handler);
  secure.listen(0, '127.0.0.1', function () {
    compat.listen(0, '127.0.0.1', function () {
      console.log(JSON.stringify({ https: secure.address().port, http2: compat.address().port }));
    });
  });
}

function forkScenario() {
  const { fork } = require('child_process');
  const relay = function (who) {
    return function (message) { message.who = who; console.log(JSON.stringify(message)); };
  };
  // Both inherit NODE_OPTIONS. The first serves no requests; the second also gets the copy through execArgv (it loads
  // the preload twice) and serves one request to itself.
  fork(process.env.TEST_CHILD).on('message', relay('plain'));
  fork(process.env.TEST_CHILD, ['serve'], { execArgv: ['--require', process.env.TEST_COPY] }).on('message', relay('twice'));
}

const CHILD_SOURCE = [
  "'use strict';",
  "const http = require('http');",
  'const sample = () => ({',
  '  now: Date.now(), year: new Date().getFullYear(), tz: process.env.TZ === undefined ? null : process.env.TZ,',
  '  hours: new Date(Date.UTC(2026, 0, 15, 12)).getHours(), number: (1234.5).toLocaleString()',
  '});',
  'let inside = null;',
  "if (process.argv[2] === 'serve') {",
  '  const server = http.createServer((req, res) => res.end(JSON.stringify(sample())));',
  "  server.listen(0, '127.0.0.1', () => http.get({ host: '127.0.0.1', port: server.address().port }, (response) => {",
  "    let body = ''; response.on('data', (chunk) => { body += chunk; });",
  "    response.on('end', () => { inside = JSON.parse(body); });",
  '  }));',
  '}',
  'const report = () => process.send({ outside: sample(), inside: inside });',
  'report();',
  'setInterval(report, 50);',
  "process.on('disconnect', () => process.exit(0));",
  ''
].join('\n');

// MARK: Checks

function checkActive() {
  startClock({ timeZone: 'America/Chicago', locale: 'de-DE' });
  const t0 = Date.now();
  const result = runSync(activeScenario, studioEnv(preload));
  const t1 = Date.now();
  if (result.error || !result.inside) return check('active scenario ran', false, result.error || result);
  const range = testRange(t0, t1);
  const r = result.inside;
  check('in a request: Date.now() is the test time plus the elapsed real time', within(r.now, range), r.now - TEST_TIME);
  check('in a request: new Date() is the test time', within(r.newDate, range), r.newDate - TEST_TIME);
  check('in a request: new Date().getFullYear() is the test year', r.year === 2024, r.year);
  check('in a request: Date() returns a string of test now', r.dateCallType === 'string' && r.dateCall.indexOf('Feb 29 2024') >= 0 &&
    r.dateCall.indexOf('GMT-0600') >= 0, r.dateCall);
  check('new Date(0) is unchanged', r.epoch === '1970-01-01T00:00:00.000Z', r.epoch);
  check('new Date(y, m, d, h) is unchanged', r.parts === '8/2020', r.parts);
  check('new Date(string) is unchanged', r.isoString === 1577836800000, r.isoString);
  check('Date.UTC and Date.parse are unchanged', r.utc === 1577836800000 && r.parse === 1577836800000, [r.utc, r.parse]);
  check('instanceof Date, its tag and constructor hold', r.instance && r.tag === '[object Date]' && r.ctor, [r.instance, r.tag, r.ctor]);
  check('Date keeps its name, length and prototype', r.shape === 'Date/7/true', r.shape);
  check('dates Node creates (fs.Stats) are instanceof Date', r.nodeDate === true);
  check('in a request: a subclass of Date works', r.subclass === true);
  check('in a request: performance.now() stays on the real clock', within(r.performance, [t0 - 2000, t1 + 2000]), r.performance - t0);
  check('TZ is the scenario zone', r.tz === 'America/Chicago', r.tz);
  check('getHours() follows the scenario zone', r.hours === 6, r.hours);
  check('Intl resolves the scenario zone', r.intlZone === 'America/Chicago', r.intlZone);
  check('in a request: Number toLocaleString() uses the scenario locale', r.number === TEST_NUMBER, r.number);
  check('in a request: an explicit locale is respected', r.numberExplicit === REAL_NUMBER && r.numberFormatExplicit === REAL_NUMBER &&
    r.intlLocaleExplicit === 'en-US' && r.dateLocaleExplicit === '1/15/2026', [r.numberExplicit, r.numberFormatExplicit, r.intlLocaleExplicit, r.dateLocaleExplicit]);
  check('in a request: Intl.NumberFormat with and without new', r.numberFormat === TEST_NUMBER + ' ' + TEST_NUMBER, r.numberFormat);
  check('in a request: Intl.DateTimeFormat().resolvedOptions().locale', r.intlLocale === 'de-DE', r.intlLocale);
  check('in a request: toLocaleDateString/TimeString use locale and zone', r.dateLocale === '15.1.2026' && r.timeLocale === '06:00:00', [r.dateLocale, r.timeLocale]);
  check('in a request: localeCompare uses the locale, an explicit one is respected', r.compare === '-1/1', r.compare);
  check('in a request: Collator, ListFormat, RelativeTimeFormat, PluralRules', r.collator === true && r.list === 'a und b' &&
    r.relative === 'in 1 Tag' && r.plural === true, [r.collator, r.list, r.relative, r.plural]);
  check('wrapped Intl keeps instanceof, name and statics', r.intlShape === 'true/NumberFormat/1', r.intlShape);
  if (r.navigator !== null) check('in a request: navigator.language follows the locale', r.navigator === 'de-DE,de-DE', r.navigator);
  check('in a request: test time and locale after await', within(r.afterAwait.now, range) && r.afterAwait.number === TEST_NUMBER, r.afterAwait);
  check('in a request: test time and locale in a setTimeout of the handler', within(r.inTimeout.now, range) && r.inTimeout.number === TEST_NUMBER, r.inTimeout);
  check('in a request: test time while the response streams', r.streamed.length > 60 && r.streamed.every(function (now) { return within(now, range); }),
    r.streamed.filter(function (now) { return !within(now, range); }).slice(0, 3));
  check('requiring a second copy returns the first one', r.sameApi === true);
  check('a second copy does not shift the clock again', within(r.nowAfterSecond, range), r.nowAfterSecond - TEST_TIME);

  const o = result.outside;
  const real = realRange(t0, t1);
  check('outside a request: Date.now(), new Date() and Date() keep the real clock', within(o.now, real) && within(o.newDate, real) &&
    o.year === new Date(t0).getFullYear() && o.dateCall.indexOf(String(new Date(t0).getFullYear())) >= 0, [o.now - t0, o.year, o.dateCall]);
  check('outside a request: the default locale stays the process one', o.number === REAL_NUMBER && o.intlLocale === 'en-US' &&
    o.numberFormat === REAL_NUMBER + ' ' + REAL_NUMBER && o.dateLocale === '1/15/2026' && o.compare === '-1/1' &&
    o.list === 'a and b' && (o.navigator === null || o.navigator === 'en-US,en-US'),
  [o.number, o.intlLocale, o.numberFormat, o.dateLocale, o.compare, o.list, o.navigator]);
  check('outside a request: the zone is process-wide', o.tz === 'America/Chicago' && o.hours === 6, [o.tz, o.hours]);
  // r.performance is the real time at which the handler started.
  const during = result.ticks.filter(function (tick) { return tick.now >= r.performance; });
  check('a timer started before the server keeps the real clock and locale while a request runs', during.length >= 3 &&
    result.ticks.every(function (tick) { return within(tick.now, real) && tick.number === REAL_NUMBER; }),
  result.ticks.filter(function (tick) { return !within(tick.now, real) || tick.number !== REAL_NUMBER; }).slice(0, 3));
  check('the client of the request keeps the real clock', within(result.after.now, real) && result.after.number === REAL_NUMBER, result.after);
}

function checkInactive() {
  const variants = [
    ['no clock variable', baseEnv({ NODE_OPTIONS: '--require "' + preload + '"' }), null],
    ['a clock file that is not JSON', studioEnv(preload), 'half {"testTime": 17'],
    ['a clock file with a wrong testTime', studioEnv(preload), JSON.stringify({ testTime: 'soon', anchor: 1, timeZone: 'America/Chicago' })],
    ['a missing clock file', studioEnv(preload, { MARKVIEW_STUDIO_CLOCK: path.join(work, 'missing.json') }), null],
    ['a relative clock path', studioEnv(preload, { MARKVIEW_STUDIO_CLOCK: 'clock.json' }), null]
  ];
  variants.forEach(function (variant) {
    if (variant[2] !== null) writeClock(variant[2]);
    const t0 = Date.now();
    const r = runSync(inactiveScenario, variant[1]);
    const t1 = Date.now();
    const unchanged = within(r.now, realRange(t0, t1)) && r.nativeDate === true && r.hooked === false &&
      r.number === REAL_NUMBER && r.tz === 'Asia/Tokyo' && r.hours === 21;
    check(variant[0] + ': nothing changes', unchanged, r);
  });
}

async function checkLive() {
  startClock({ timeZone: 'America/Chicago', locale: 'de-DE' });
  const t0 = Date.now();
  const live = runLive(liveScenario, studioEnv(preload));
  try {
    const first = await live.waitFor(function () { return true; }, 5000);
    check('a running server starts on the test clock', first && first.inside.year === 2024 && first.inside.tz === 'America/Chicago' &&
      first.inside.hours === 6 && first.inside.number === TEST_NUMBER, first || live.stderr());
    check('a running server keeps the real clock outside requests', first && within(first.outside.now, realRange(t0, first.receivedAt)) &&
      first.outside.number === REAL_NUMBER, first && first.outside);
    writeClock('{"testTime": 19');
    await sleep(700);
    const kept = live.lines[live.lines.length - 1];
    check('a half-written clock file keeps the last good configuration', kept && kept.inside.year === 2024 &&
      kept.inside.tz === 'America/Chicago' && kept.inside.number === TEST_NUMBER, kept);

    const later = Date.UTC(2030, 5, 1, 12);
    const written = Date.now();
    anchor = written;
    writeClock({ testTime: later, anchor: written, timeZone: null, locale: 'fr-FR' });
    const moved = await live.waitFor(function (line) { return line.inside.year === 2030; }, 3000);
    check('a rewritten clock file is picked up within a second', moved && moved.receivedAt - written <= 1000,
      moved ? moved.receivedAt - written : 'not picked up in 3 s');
    check('the new test time continues from its anchor', moved && within(moved.inside.now, testRange(written, moved.receivedAt, later)),
      moved && moved.inside.now - later);
    check('a dropped zone restores the original TZ', moved && moved.inside.tz === 'Asia/Tokyo' && moved.inside.hours === 21, moved);
    check('a changed locale is applied', moved && moved.inside.number === new Intl.NumberFormat('fr-FR').format(1234.5), moved && moved.inside.number);
    check('outside requests the clock stays real after the rewrite', moved && within(moved.outside.now, realRange(written, moved.receivedAt)) &&
      moved.outside.number === REAL_NUMBER, moved && moved.outside);

    const real = Date.now();
    writeClock({ testTime: null, timeZone: 'Europe/Berlin', locale: null });
    const plain = await live.waitFor(function (line) { return line.inside.tz === 'Europe/Berlin'; }, 3000);
    check('a file without testTime and locale returns requests to the real clock and locale', plain &&
      within(plain.inside.now, realRange(real, plain.receivedAt)) && plain.inside.hours === 13 && plain.inside.number === REAL_NUMBER, plain);
  } finally {
    live.stop();
  }
}

function checkWorker() {
  startClock({ locale: 'de-DE' });
  const t0 = Date.now();
  const r = runSync(workerScenario, studioEnv(preload));
  const t1 = Date.now();
  check('a worker thread serving a request sees the test clock and locale there', r.inside && within(r.inside.now, testRange(t0, t1)) &&
    r.inside.number === TEST_NUMBER, r);
  check('a worker thread keeps the real clock and locale outside requests', r.outside && within(r.outside.now, realRange(t0, t1)) &&
    r.outside.number === REAL_NUMBER, r);
}

function checkConvert(convertSetCookie) {
  const cases = [
    ['test clock a day ahead', 'a=1; Path=/; Expires=Thu, 02 Jan 2031 00:00:00 GMT; Max-Age=3600; HttpOnly', DAY,
      'a=1; Path=/; Expires=Wed, 01 Jan 2031 00:00:00 GMT; Max-Age=3600; HttpOnly'],
    ['test clock a day behind, lower-case attribute', 'a=1; expires=Wed, 01 Jan 2031 00:00:00 GMT', -DAY,
      'a=1; expires=Thu, 02 Jan 2031 00:00:00 GMT'],
    ['spaces around the attribute are kept', 'a=1;expires = Thu, 02 Jan 2031 00:00:00 GMT ;Secure', DAY,
      'a=1;expires = Wed, 01 Jan 2031 00:00:00 GMT ;Secure'],
    ['a cookie named expires is not an attribute', 'expires=Thu, 02 Jan 2031 00:00:00 GMT; Path=/', DAY,
      'expires=Thu, 02 Jan 2031 00:00:00 GMT; Path=/'],
    ['an unreadable date is left alone', 'a=1; Expires=someday', DAY, 'a=1; Expires=someday'],
    ['Max-Age alone is left alone', 'a=1; Max-Age=60', DAY, 'a=1; Max-Age=60'],
    ['a deleting cookie stays in the past', 'a=; Expires=Thu, 01 Jan 1970 00:00:00 GMT', DAY,
      'a=; Expires=Thu, 01 Jan 1970 00:00:00 GMT'],
    ['no offset, no change', 'a=1; Expires=Thu, 02 Jan 2031 00:00:00 GMT', 0, 'a=1; Expires=Thu, 02 Jan 2031 00:00:00 GMT']
  ];
  cases.forEach(function (c) {
    const result = convertSetCookie(c[1], c[2]);
    check('convertSetCookie: ' + c[0], result === c[3], result);
  });
  const input = ['a=1; Expires=Thu, 02 Jan 2031 00:00:00 GMT', 'b=2; Path=/'];
  const output = convertSetCookie(input, DAY);
  check('convertSetCookie: an array is converted into a copy', Array.isArray(output) && output !== input &&
    output[0] === 'a=1; Expires=Wed, 01 Jan 2031 00:00:00 GMT' && output[1] === 'b=2; Path=/' &&
    input[0] === 'a=1; Expires=Thu, 02 Jan 2031 00:00:00 GMT', output);
  check('convertSetCookie: other values pass through', convertSetCookie(5, DAY) === 5 && convertSetCookie(undefined, DAY) === undefined &&
    convertSetCookie(input, NaN) === input);
}

async function checkServer() {
  startClock({});
  const server = runLive(serverScenario, studioEnv(preload));
  try {
    const ready = await server.waitFor(function (line) { return typeof line.port === 'number'; }, 5000);
    if (!ready) return check('the cookie server started', false, server.stderr());
    const routes = ['/set', '/head', '/pairs', '/raw', '/mixed', '/later'];
    if (typeof http.ServerResponse.prototype.appendHeader === 'function') routes.push('/append');
    for (const route of routes) {
      const response = await get(ready.port, route);
      check('server ' + route + ': Expires of Set-Cookie is on the real clock', expiresTomorrow(response.cookies), response.cookies);
      if (route === '/set') {
        check('server /set: Max-Age and a cookie without Expires are untouched', /; Max-Age=86400; Path=\/$/.test(response.cookies[0] || '') &&
          response.cookies[1] === 'b=2; Path=/', response.cookies);
      }
      if (route === '/head') check('server /head: Max-Age is untouched', /; Max-Age=60$/.test(response.cookies[0] || ''), response.cookies);
      if (route === '/append') check('server /append: both appended cookies arrive', response.cookies.length === 2, response.cookies);
      if (['/head', '/pairs', '/raw', '/mixed'].indexOf(route) >= 0) check('server ' + route + ': other headers pass', response.test === 'y', response.test);
    }
    const outside = await get(ready.port, '/outside');
    check('server /outside: a Set-Cookie set outside any request is left alone', expiresTomorrow(outside.cookies), outside.cookies);
  } finally {
    server.stop();
  }
}

function makeCertificate() {
  const key = path.join(work, 'key.pem');
  const cert = path.join(work, 'cert.pem');
  // -noenc is the OpenSSL 3+ spelling of -nodes; LibreSSL only knows -nodes.
  for (const flag of ['-noenc', '-nodes']) {
    const result = spawnSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', flag, '-keyout', key, '-out', cert, '-days', '2',
      '-subj', '/CN=localhost'], { encoding: 'utf8', timeout: 30000 });
    if (result.status === 0 && fs.existsSync(key) && fs.existsSync(cert)) return { key: key, cert: cert };
  }
  return null;
}

function getSecure(port) {
  return new Promise(function (resolve) {
    https.get({ host: '127.0.0.1', port: port, rejectUnauthorized: false }, function (response) { collectBody(response, resolve); })
      .on('error', function (error) { resolve({ cookies: [], error: String(error) }); });
  });
}

function getHttp2(port) {
  return new Promise(function (resolve) {
    const session = http2.connect('https://127.0.0.1:' + port, { rejectUnauthorized: false });
    session.on('error', function (error) { resolve({ cookies: [], error: String(error) }); });
    const request = session.request({ ':path': '/' });
    let cookies = [];
    let body = '';
    request.on('response', function (headers) { cookies = headers['set-cookie'] || []; });
    request.setEncoding('utf8');
    request.on('data', function (chunk) { body += chunk; });
    request.on('end', function () {
      session.close();
      let json = null;
      try { json = JSON.parse(body); } catch (error) {}
      resolve({ cookies: cookies, json: json });
    });
    request.end();
  });
}

async function checkSecure() {
  const certificate = makeCertificate();
  if (!certificate) {
    console.log('skip https and http2: openssl could not make a self-signed certificate.');
    return;
  }
  startClock({ locale: 'de-DE' });
  const t0 = Date.now();
  const server = runLive(secureScenario, studioEnv(preload, { TEST_KEY: certificate.key, TEST_CERT: certificate.cert }));
  try {
    const ready = await server.waitFor(function (line) { return typeof line.https === 'number'; }, 5000);
    if (!ready) return check('the https and http2 servers started', false, server.stderr());
    const secure = await getSecure(ready.https);
    check('https: a handler sees the test clock and locale', secure.json && within(secure.json.now, testRange(t0, Date.now())) &&
      secure.json.number === TEST_NUMBER, secure);
    check('https: Expires of Set-Cookie is on the real clock', expiresTomorrow(secure.cookies), secure.cookies);
    const compat = await getHttp2(ready.http2);
    check('http2 compatibility API: a handler sees the test clock and locale', compat.json && within(compat.json.now, testRange(t0, Date.now())) &&
      compat.json.number === TEST_NUMBER, compat);
    check('http2 compatibility API: Expires of Set-Cookie is on the real clock', expiresTomorrow(compat.cookies), compat.cookies);
  } finally {
    server.stop();
  }
}

async function checkFork() {
  fs.writeFileSync(childScript, CHILD_SOURCE);
  startClock({ timeZone: 'America/Chicago', locale: 'de-DE' });
  const t0 = Date.now();
  const parent = runLive(forkScenario, studioEnv(preload));
  try {
    const plain = await parent.waitFor(function (l) { return l.who === 'plain'; }, 5000);
    check('a forked child that serves no requests keeps the real clock and locale', plain &&
      within(plain.outside.now, realRange(t0, plain.receivedAt)) && plain.outside.year === new Date(t0).getFullYear() &&
      plain.outside.number === REAL_NUMBER, plain || parent.stderr());
    check('a forked child inherits the scenario zone', plain && plain.outside.tz === 'America/Chicago' && plain.outside.hours === 6, plain);
    const twice = await parent.waitFor(function (l) { return l.who === 'twice' && l.inside; }, 5000);
    check('a forked child that loads the preload twice sees the test clock once in a request', twice &&
      within(twice.inside.now, testRange(t0, twice.receivedAt)) && twice.inside.year === 2024 && twice.inside.number === TEST_NUMBER,
    twice || parent.stderr());
    check('a forked child that loads the preload twice keeps the real clock outside requests', twice &&
      within(twice.outside.now, realRange(t0, twice.receivedAt)) && twice.outside.number === REAL_NUMBER, twice);
    const written = Date.now();
    writeClock({ testTime: TEST_TIME, anchor: anchor, timeZone: null, locale: 'de-DE' });
    const restored = await parent.waitFor(function (l) { return l.who === 'plain' && l.receivedAt > written && l.outside.tz !== 'America/Chicago'; }, 3000);
    check("a child restores the server's own TZ, not the inherited one", restored && restored.outside.tz === 'Asia/Tokyo' &&
      restored.outside.hours === 21, restored);
  } finally {
    parent.stop();
  }
}

async function main() {
  checkActive();
  checkInactive();
  await checkLive();
  checkWorker();
  checkConvert(require(preload).convertSetCookie);
  await checkServer();
  await checkSecure();
  await checkFork();
  console.log(failures === 0 ? 'All UI Studio Node checks passed.' : failures + ' UI Studio Node check(s) failed.');
  process.exit(failures === 0 ? 0 : 1);
}

main().catch(function (error) {
  console.log('FAIL the test driver stopped: ' + (error && error.stack || error));
  process.exit(1);
});
