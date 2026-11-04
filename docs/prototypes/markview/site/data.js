/*
 * data.js: the prototype's in-memory backend, written by MarkView. seed.js supplies the records: DB.seed({Entity: [records]}).
 * Entity names are the plan's entity names exactly; every record has a string `id`.
 *
 * DB.list(entity, {q, filter, sort, dir, page, pageSize}) -> {items, total, page, pageSize}
 *   q: case-insensitive text search over the record's values. filter: {field: value}, where value may be an array of
 *   accepted values; '' and null match everything; or a function(record) -> boolean. sort: a field; dir: 'asc' or 'desc'.
 *   page counts from 1; without pageSize every matching item is returned.
 * DB.all(entity) -> every record. DB.get(entity, id) -> the record or null. DB.find(entity, filter) -> the first match or null.
 * DB.create(entity, record) -> the stored record with an `id` (kept when given). DB.update(entity, id, patch) -> the record.
 * DB.remove(entity, id) -> true when it existed. DB.count(entity, filter) -> number. DB.entities() -> the entity names.
 * DB.reset() restores the seed. DB.on(fn) calls fn(entity) after every change.
 * DB.days(n, hour) -> an ISO date-time n days from today (negative: in the past), at `hour` o'clock (default 10).
 * Records are copies: change them with DB.update. Changes persist in localStorage until "Reset demo data".
 * With "Force empty state" (Prototype menu) DB.list, DB.all and DB.count see no records.
 */
(function () {
  'use strict';
  var DB = window.DB = window.DB || {};
  var seed = {}, state = null, listeners = [];
  var meta = document.querySelector('meta[name="mv-prototype"]');
  var KEY = 'mv-proto-db:' + (meta ? meta.content : location.pathname);

  function clone(value) { return value == null ? value : JSON.parse(JSON.stringify(value)); }
  function fingerprint(text) { var hash = 5381; for (var i = 0; i < text.length; i++) hash = ((hash << 5) + hash + text.charCodeAt(i)) | 0; return String(hash); }
  var version = fingerprint('');
  function load() {
    if (state) return state;
    try {
      var saved = JSON.parse(localStorage.getItem(KEY) || 'null');
      if (saved && saved.version === version && saved.data) { state = saved.data; return state; }
    } catch (e) {}
    state = clone(seed);
    return state;
  }
  function save(entity) {
    try { localStorage.setItem(KEY, JSON.stringify({ version: version, data: state })); } catch (e) {}
    listeners.forEach(function (fn) { try { fn(entity); } catch (e) { if (window.console) console.error(e); } });
  }
  function name(entity) {
    var data = load();
    if (data[entity]) return entity;
    var wanted = String(entity).toLowerCase();
    for (var key in data) if (key.toLowerCase() === wanted || key.toLowerCase() + 's' === wanted || key.toLowerCase() === wanted + 's') return key;
    data[entity] = [];
    return entity;
  }
  function table(entity) { return load()[name(entity)]; }
  function forcedEmpty() { return !!(window.App && App.proto && App.proto().empty); }
  function matches(record, filter) {
    if (!filter) return true;
    if (typeof filter === 'function') return !!filter(record);
    return Object.keys(filter).every(function (field) {
      var want = filter[field];
      if (want === '' || want == null) return true;
      var have = record[field];
      if (Array.isArray(want)) return want.some(function (item) { return String(item) === String(have); });
      if (typeof want === 'function') return !!want(have, record);
      if (Array.isArray(have)) return have.some(function (item) { return String(item) === String(want); });
      return String(have) === String(want);
    });
  }
  function text(value) {
    if (value == null) return '';
    if (typeof value === 'object') return Object.keys(value).map(function (key) { return text(value[key]); }).join(' ');
    return String(value);
  }
  function compare(a, b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    if (typeof a === 'number' && typeof b === 'number') return a - b;
    if (typeof a === 'boolean' || typeof b === 'boolean') return (a ? 1 : 0) - (b ? 1 : 0);
    return String(a).localeCompare(String(b), undefined, { numeric: true, sensitivity: 'base' });
  }
  function newId(entity, rows) {
    var stem = String(entity).toLowerCase().replace(/[^a-z0-9]+/g, '').slice(0, 4) || 'rec';
    var id;
    do { id = stem + '-' + Math.random().toString(36).slice(2, 8); } while (rows.some(function (row) { return String(row.id) === id; }));
    return id;
  }
  function index(rows, id) {
    for (var i = 0; i < rows.length; i++) if (String(rows[i].id) === String(id)) return i;
    return -1;
  }

  DB.seed = function (data) {
    seed = {};
    Object.keys(data || {}).forEach(function (entity) {
      var rows = Array.isArray(data[entity]) ? data[entity] : [];
      seed[entity] = rows.map(function (row, i) {
        var copy = clone(row) || {};
        if (copy.id == null) copy.id = String(entity).toLowerCase().replace(/[^a-z0-9]+/g, '').slice(0, 4) + '-' + (i + 1);
        copy.id = String(copy.id);
        return copy;
      });
    });
    // Entity names and ids only: dates computed with DB.days must not discard the saved changes every day.
    version = fingerprint(Object.keys(seed).map(function (entity) { return entity + ':' + seed[entity].map(function (row) { return row.id; }).join(','); }).join(';'));
    state = null;
  };
  DB.entities = function () { return Object.keys(load()); };
  DB.list = function (entity, options) {
    options = options || {};
    var rows = forcedEmpty() ? [] : table(entity).filter(function (row) { return matches(row, options.filter); });
    if (options.q) {
      var q = String(options.q).toLowerCase().trim();
      if (q) rows = rows.filter(function (row) { return text(row).toLowerCase().indexOf(q) >= 0; });
    }
    if (options.sort) {
      var field = options.sort, sign = options.dir === 'desc' ? -1 : 1;
      rows = rows.slice().sort(function (a, b) { return sign * compare(a[field], b[field]); });
    }
    var total = rows.length;
    var pageSize = options.pageSize ? Math.max(1, Number(options.pageSize)) : Math.max(total, 1);
    var page = Math.min(Math.max(1, Number(options.page) || 1), Math.max(1, Math.ceil(total / pageSize)));
    return { items: clone(rows.slice((page - 1) * pageSize, page * pageSize)), total: total, page: page, pageSize: pageSize };
  };
  DB.all = function (entity) { return forcedEmpty() ? [] : clone(table(entity)); };
  DB.count = function (entity, filter) { return forcedEmpty() ? 0 : table(entity).filter(function (row) { return matches(row, filter); }).length; };
  DB.get = function (entity, id) { var rows = table(entity), at = index(rows, id); return at < 0 ? null : clone(rows[at]); };
  DB.find = function (entity, filter) { var row = table(entity).filter(function (item) { return matches(item, filter); })[0]; return row ? clone(row) : null; };
  DB.create = function (entity, record) {
    var rows = table(entity), copy = clone(record) || {};
    copy.id = copy.id == null || index(rows, copy.id) >= 0 ? newId(entity, rows) : String(copy.id);
    rows.unshift(copy);
    save(entity);
    return clone(copy);
  };
  DB.update = function (entity, id, patch) {
    var rows = table(entity), at = index(rows, id);
    if (at < 0) throw new Error(entity + ' ' + id + ' does not exist');
    var next = clone(patch) || {};
    for (var key in next) if (key !== 'id') rows[at][key] = next[key];
    save(entity);
    return clone(rows[at]);
  };
  DB.remove = function (entity, id) {
    var rows = table(entity), at = index(rows, id);
    if (at < 0) return false;
    rows.splice(at, 1);
    save(entity);
    return true;
  };
  DB.reset = function () {
    state = clone(seed);
    try { localStorage.removeItem(KEY); } catch (e) {}
    save(null);
  };
  DB.on = function (fn) { if (typeof fn === 'function') listeners.push(fn); };
  DB.days = function (n, hour) {
    var d = new Date();
    d.setHours(hour == null ? 10 : hour, 0, 0, 0);
    d.setDate(d.getDate() + (Number(n) || 0));
    return d.toISOString();
  };
})();
