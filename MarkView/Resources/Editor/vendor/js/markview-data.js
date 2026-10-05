// Data viewers (Task 84): tables (CSV, TSV, PSV, JSON Lines/NDJSON, Parquet, SQLite) with SQL,
// sorting, filters, search, column statistics and export; and logs (.log, .out, .txt) with
// levels, search, error navigation and following the end of the file.
//
// Swift calls window.setDataContent({src, kind, name, reload}); the file's bytes come from
// `markview-data:` (DataFileSchemeHandler). SQL runs in sql.js (SQLite in WebAssembly) from
// vendor/js/data.bundle.js, loaded on first use. Data files are never written back.
(function () {
    'use strict';

    const container = document.getElementById('data-container');
    if (!container) return;

    const css = `
    .data-container { display: none; flex: 1; min-height: 0; flex-direction: column; background: var(--bg-primary); color: var(--text-primary); font-family: var(--font-sans); font-size: calc(12px * var(--ui-scale, 1)); }
    .data-container.visible { display: flex; }
    .dv-bar { display: flex; align-items: center; gap: 6px; padding: 6px 10px; border-bottom: 1px solid var(--border-color); background: var(--bg-secondary); flex-wrap: wrap; }
    .dv-bar .dv-title { font-weight: 600; margin-right: 6px; }
    .dv-bar .dv-meta { color: var(--text-secondary); }
    .dv-bar .dv-spacer { flex: 1; }
    .dv-bar input[type=search], .dv-bar input[type=text], .dv-bar select { background: var(--bg-primary); color: var(--text-primary); border: 1px solid var(--border-color); border-radius: 4px; padding: 3px 6px; font: inherit; }
    .dv-bar input[type=search] { width: 220px; }
    .dv-btn { background: var(--bg-primary); color: var(--text-primary); border: 1px solid var(--border-color); border-radius: 4px; padding: 3px 8px; cursor: pointer; font: inherit; }
    .dv-btn:hover { border-color: var(--accent-primary); }
    .dv-btn.on { background: var(--accent-primary); color: #fff; border-color: var(--accent-primary); }
    .dv-btn:disabled { opacity: .5; cursor: default; }
    .dv-sql { display: none; padding: 6px 10px; border-bottom: 1px solid var(--border-color); gap: 6px; }
    .dv-sql.visible { display: flex; }
    .dv-sql textarea { flex: 1; min-height: 54px; resize: vertical; font-family: var(--font-mono); font-size: calc(12px * var(--ui-scale, 1)); background: var(--bg-primary); color: var(--text-primary); border: 1px solid var(--border-color); border-radius: 4px; padding: 6px; }
    .dv-sql .dv-sql-side { display: flex; flex-direction: column; gap: 4px; }
    .dv-msg { padding: 4px 10px; color: var(--text-secondary); border-bottom: 1px solid var(--border-color); white-space: pre-wrap; }
    .dv-msg.error { color: var(--accent-danger); }
    .dv-msg:empty { display: none; }
    .dv-body { flex: 1; min-height: 0; display: flex; }
    .dv-grid { flex: 1; min-width: 0; overflow: auto; position: relative; font-family: var(--font-mono); }
    .dv-grid table { border-collapse: separate; border-spacing: 0; table-layout: fixed; }
    .dv-grid th, .dv-grid td { border-right: 1px solid var(--border-color-light); border-bottom: 1px solid var(--border-color-light); padding: 0 6px; height: 24px; max-width: 420px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; text-align: left; }
    .dv-grid thead th { position: sticky; top: 0; background: var(--bg-secondary); z-index: 2; cursor: pointer; font-family: var(--font-sans); font-weight: 600; user-select: none; }
    .dv-grid thead tr.dv-filters th { top: 25px; cursor: default; padding: 2px 3px; }
    .dv-grid thead tr.dv-filters input { width: 100%; box-sizing: border-box; background: var(--bg-primary); color: var(--text-primary); border: 1px solid var(--border-color); border-radius: 3px; padding: 1px 4px; font: inherit; font-family: var(--font-mono); }
    .dv-grid th.dv-rownum, .dv-grid td.dv-rownum { position: sticky; left: 0; background: var(--bg-secondary); color: var(--text-tertiary); text-align: right; z-index: 1; width: 56px; min-width: 56px; }
    .dv-grid thead th.dv-rownum { z-index: 3; }
    .dv-grid td.num { text-align: right; }
    .dv-grid td.null { color: var(--text-tertiary); font-style: italic; }
    .dv-grid tr.sel td { background: var(--selection-bg); }
    .dv-grid td.cur { outline: 1px solid var(--accent-primary); outline-offset: -1px; }
    .dv-side { width: 300px; border-left: 1px solid var(--border-color); overflow: auto; padding: 8px 10px; display: none; background: var(--bg-secondary); }
    .dv-side.visible { display: block; }
    .dv-side h4 { margin: 4px 0 6px; font-size: calc(12px * var(--ui-scale, 1)); }
    .dv-side table { width: 100%; border-collapse: collapse; font-family: var(--font-mono); }
    .dv-side td { padding: 2px 4px; border-bottom: 1px solid var(--border-color-light); vertical-align: top; word-break: break-word; }
    .dv-side pre { white-space: pre-wrap; word-break: break-word; font-family: var(--font-mono); margin: 0; }
    .dv-side .dv-tablelist button { display: block; width: 100%; text-align: left; margin-bottom: 2px; }
    .dv-log { flex: 1; min-width: 0; overflow: auto; position: relative; font-family: var(--font-mono); font-size: calc(12px * var(--ui-scale, 1)); }
    .dv-log .ln { display: flex; height: 18px; line-height: 18px; white-space: pre; }
    .dv-log.wrap .ln { height: auto; white-space: pre-wrap; word-break: break-word; }
    .dv-log .no { width: 64px; min-width: 64px; text-align: right; padding-right: 10px; color: var(--text-tertiary); user-select: none; position: sticky; left: 0; background: var(--bg-primary); }
    .dv-log .tx { flex: 1; padding-right: 10px; }
    .dv-log .ln.error .tx, .dv-log .ln.fatal .tx { color: var(--accent-danger); }
    .dv-log .ln.warn .tx { color: var(--accent-warning); }
    .dv-log .ln.debug .tx, .dv-log .ln.trace .tx { color: var(--text-secondary); }
    .dv-log .ln.cur { background: var(--selection-bg); }
    .dv-log .ts { color: var(--accent-secondary); }
    .dv-log mark { background: rgba(255, 200, 0, .45); color: inherit; border-radius: 2px; }
    .dv-level { display: inline-flex; gap: 4px; align-items: center; }
    .dv-level .dv-btn .n { opacity: .75; margin-left: 3px; }
    `;
    const style = document.createElement('style');
    style.textContent = css;
    document.head.appendChild(style);

    const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
    const q = (name) => '"' + String(name).replace(/"/g, '""') + '"';
    const fmtCount = (n) => Number(n).toLocaleString();

    let current = null;          // { kind, name, src, viewer }
    let bundle = null;

    function loadBundle() {
        if (window.MVData) return Promise.resolve(window.MVData);
        if (bundle) return bundle;
        bundle = new Promise((resolve, reject) => {
            const script = document.createElement('script');
            script.src = 'vendor/js/data.bundle.js';
            script.onload = () => resolve(window.MVData);
            script.onerror = () => reject(new Error('The data libraries could not be loaded.'));
            document.head.appendChild(script);
        });
        return bundle;
    }

    function enterDataView() {
        if (window.leaveCodeView) window.leaveCodeView();
        if (window.leaveArchitectureView) window.leaveArchitectureView();
        if (window.leaveCanvasView) window.leaveCanvasView();
        if (typeof leaveInsightView === 'function') leaveInsightView();
        if (typeof DOM !== 'undefined') {
            DOM.editorPane.style.display = 'none';
            DOM.previewPane.style.display = 'none';
        }
        const toolbar = document.getElementById('wysiwyg-toolbar');
        if (toolbar) toolbar.style.display = 'none';
        document.body.classList.add('data-mode');
        container.classList.add('visible');
    }

    window.leaveDataView = function () {
        if (!container.classList.contains('visible')) return;
        container.classList.remove('visible');
        document.body.classList.remove('data-mode');
        const toolbar = document.getElementById('wysiwyg-toolbar');
        if (toolbar) toolbar.style.display = '';
        if (current && current.viewer && current.viewer.destroy) current.viewer.destroy();
        current = null;
        container.innerHTML = '';
    };

    async function fetchBytes(src) {
        const response = await fetch(src, { cache: 'no-store' });
        if (!response.ok) throw new Error('Could not read the file (' + response.status + ').');
        return new Uint8Array(await response.arrayBuffer());
    }

    function decodeText(bytes) {
        try { return new TextDecoder('utf-8', { fatal: true }).decode(bytes); }
        catch (e) { return new TextDecoder('windows-1252').decode(bytes); }
    }

    function message(text, isError) {
        container.innerHTML = '<div class="dv-msg' + (isError ? ' error' : '') + '">' + esc(text) + '</div>';
    }

    window.setDataContent = async function (info) {
        enterDataView();
        const sameFile = current && current.src === info.src;
        if (info.reload && sameFile && current.viewer && current.viewer.reload) {
            try { current.viewer.reload(await fetchBytes(info.src)); } catch (e) { /* keep what is shown */ }
            return;
        }
        if (current && current.viewer && current.viewer.destroy) current.viewer.destroy();
        current = { kind: info.kind, name: info.name, src: info.src, viewer: null };
        const mine = current;
        message('Loading ' + info.name + '…');
        if (typeof DOM !== 'undefined' && DOM.statusMode) DOM.statusMode.textContent = info.kind.toUpperCase();
        try {
            const bytes = await fetchBytes(info.src);
            if (current !== mine) return;
            if (info.kind === 'log') {
                mine.viewer = LogViewer(container, info.name, bytes);
            } else {
                const lib = await loadBundle();
                if (current !== mine) return;
                mine.viewer = await TableViewer(container, info, bytes, lib);
            }
        } catch (error) {
            if (current === mine) message(String(error && error.message || error), true);
        }
    };

    // ------------------------------------------------------------------ Tables

    /** Rows of a text table: header row + objects, by format. */
    function parseText(kind, name, text, lib) {
        const ext = (name.split('.').pop() || '').toLowerCase();
        if (ext === 'har') {
            // HTTP Archive (browser network log): one row per request.
            const har = JSON.parse(text);
            const entries = (har.log && har.log.entries) || [];
            const rows = entries.map((e) => ({
                started: e.startedDateTime, method: e.request && e.request.method, url: e.request && e.request.url,
                status: e.response && e.response.status, status_text: e.response && e.response.statusText,
                mime: e.response && e.response.content && e.response.content.mimeType,
                size: e.response && (e.response.content && e.response.content.size >= 0 ? e.response.content.size : e.response.bodySize),
                time_ms: e.time !== undefined ? Math.round(e.time * 10) / 10 : null,
                wait_ms: e.timings && e.timings.wait, server_ip: e.serverIPAddress || null,
                request_headers: e.request && JSON.stringify(e.request.headers), response_headers: e.response && JSON.stringify(e.response.headers),
            }));
            return { rows, errors: [], note: (har.log && har.log.creator ? har.log.creator.name + ' ' + (har.log.creator.version || '') : '') };
        }
        if (ext === 'jsonl' || ext === 'ndjson') {
            const rows = [];
            const errors = [];
            text.split(/\r?\n/).forEach((line, index) => {
                if (!line.trim()) return;
                try { rows.push(flatten(JSON.parse(line))); } catch (e) { if (errors.length < 5) errors.push('Line ' + (index + 1) + ': ' + e.message); }
            });
            return { rows, errors, note: '' };
        }
        const delimiter = ext === 'tsv' || ext === 'tab' ? '\t' : ext === 'psv' ? '|' : '';
        const parsed = lib.Papa.parse(text, { header: true, skipEmptyLines: 'greedy', delimiter, dynamicTyping: false });
        const errors = parsed.errors.slice(0, 5).map((e) => (e.row !== undefined ? 'Row ' + (e.row + 2) + ': ' : '') + e.message);
        return { rows: parsed.data, errors, note: parsed.meta.delimiter && !delimiter ? 'delimiter ' + JSON.stringify(parsed.meta.delimiter) : '' };
    }

    /** Nested objects become dotted columns ("meta.h"), up to three levels; arrays stay JSON. */
    function flatten(value, prefix = '', out = {}, depth = 0) {
        if (value === null || typeof value !== 'object' || Array.isArray(value) || depth >= 3) {
            out[prefix || 'value'] = value;
            return out;
        }
        const keys = Object.keys(value);
        if (!keys.length && prefix) out[prefix] = '{}';
        for (const key of keys) flatten(value[key], prefix ? prefix + '.' + key : key, out, depth + 1);
        return out;
    }

    function cellValue(value) {
        if (value === null || value === undefined) return null;
        if (typeof value === 'bigint') return Number.isSafeInteger(Number(value)) ? Number(value) : value.toString();
        if (value instanceof Date) return value.toISOString();
        if (value instanceof Uint8Array) return '0x' + Array.from(value.slice(0, 32), (b) => b.toString(16).padStart(2, '0')).join('') + (value.length > 32 ? '…' : '');
        if (typeof value === 'object') return JSON.stringify(value, (k, v) => typeof v === 'bigint' ? v.toString() : v);
        if (typeof value === 'boolean') return value ? 1 : 0;
        return value;
    }

    /** Put `rows` (objects) into table "data", typing each column numeric when every value is. */
    function loadRows(db, rows, tableName) {
        const table = q(tableName || 'data');
        const columns = [];
        const seen = new Set();
        for (const row of rows.slice(0, 2000)) for (const key of Object.keys(row || {})) if (!seen.has(key)) { seen.add(key); columns.push(key); }
        for (const row of rows) for (const key of Object.keys(row || {})) if (!seen.has(key)) { seen.add(key); columns.push(key); }
        if (!columns.length) columns.push('value');
        const numeric = columns.map((col) => {
            let any = false;
            for (const row of rows) {
                const v = row && row[col];
                if (v === null || v === undefined || v === '') continue;
                if (typeof v === 'number' || typeof v === 'bigint') { any = true; continue; }
                if (typeof v === 'string' && /^\s*-?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?\s*$/.test(v)) { any = true; continue; }
                return false;
            }
            return any;
        });
        db.run('CREATE TABLE ' + table + ' (' + columns.map((c, i) => q(c) + (numeric[i] ? ' NUMERIC' : ' TEXT')).join(', ') + ')');
        const insert = db.prepare('INSERT INTO ' + table + ' VALUES (' + columns.map(() => '?').join(',') + ')');
        db.run('BEGIN');
        for (const row of rows) {
            insert.run(columns.map((c, i) => {
                const v = cellValue(row ? row[c] : null);
                if (v === '' || v === null) return null;
                return numeric[i] ? Number(v) : (typeof v === 'number' ? String(v) : v);
            }));
        }
        db.run('COMMIT');
        insert.free();
        return columns;
    }

    async function TableViewer(root, info, bytes, lib) {
        const SQL = await lib.sql();
        const isSQLite = info.kind === 'sqlite';
        const ext = (info.name.split('.').pop() || '').toLowerCase();
        let sheetNames = null;     // an Excel workbook: one table per sheet
        let db;
        let info2 = '';                 // a line about the source (rows, delimiter, row groups…)
        let parquetDetails = null;
        const notes = [];
        if (isSQLite) {
            db = new SQL.Database(bytes);
        } else {
            db = new SQL.Database();
            let rows;
            if (info.kind === 'parquet') {
                const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
                const metadata = lib.parquet.metadata(buffer);
                const total = Number(metadata.num_rows);
                const limit = 500000;
                rows = await lib.parquet.rows(buffer, total > limit ? { rowEnd: limit } : {});
                if (total > limit) notes.push('Showing the first ' + fmtCount(limit) + ' of ' + fmtCount(total) + ' rows.');
                parquetDetails = describeParquet(metadata, lib);
                info2 = metadata.row_groups.length + (metadata.row_groups.length === 1 ? ' row group' : ' row groups');
            } else if (ext === 'xlsx' || ext === 'xlsm') {
                const sheets = readWorkbook(bytes, lib);
                sheetNames = sheets.map((sheet) => sheet.name);
                sheets.forEach((sheet) => loadRows(db, sheet.rows, sheet.name));
                info2 = sheets.length + (sheets.length === 1 ? ' sheet' : ' sheets');
            } else {
                const parsed = parseText(info.kind, info.name, decodeText(bytes), lib);
                rows = parsed.rows;
                parsed.errors.forEach((e) => notes.push(e));
                info2 = parsed.note;
            }
            if (rows) loadRows(db, rows);
        }

        const tables = isSQLite
            ? db.exec("SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY type, name")[0]?.values.map((r) => r[0]) || []
            : sheetNames || ['data'];
        const manyTables = isSQLite || !!sheetNames;
        let table = tables[0] || '';
        let baseSQL = table ? 'SELECT * FROM ' + q(table) : '';
        let sort = { column: null, desc: false };
        let filters = {};
        let search = '';
        let result = { columns: [], rows: [], total: 0, truncated: false };
        let selected = -1;
        let currentColumn = -1;
        const ROW = 25, LIMIT = 200000;

        root.innerHTML = `
          <div class="dv-bar">
            <span class="dv-title">${esc(info.name)}</span>
            ${manyTables ? '<select class="dv-table" title="' + (sheetNames ? 'Sheet' : 'Table or view') + '"></select>' : ''}
            <span class="dv-meta dv-count"></span>
            <span class="dv-spacer"></span>
            <input type="search" class="dv-search" placeholder="Search all columns">
            <button class="dv-btn dv-sqlbtn" title="Query with SQL (table: ${manyTables ? 'each ' + (sheetNames ? 'sheet' : 'table') + ' by name' : 'data'})">SQL</button>
            <button class="dv-btn dv-stats" title="Statistics of the selected column">Column stats</button>
            ${parquetDetails || isSQLite ? '<button class="dv-btn dv-schema">Schema</button>' : ''}
            <button class="dv-btn dv-export" title="Save the rows shown as CSV">Export CSV</button>
            <button class="dv-btn dv-copy" title="Copy the rows shown as TSV (paste into a spreadsheet)">Copy</button>
          </div>
          <div class="dv-sql">
            <textarea spellcheck="false"></textarea>
            <div class="dv-sql-side">
              <button class="dv-btn dv-run on" title="⌘↩">Run</button>
              <button class="dv-btn dv-reset">Reset</button>
            </div>
          </div>
          <div class="dv-msg"></div>
          <div class="dv-body"><div class="dv-grid"></div><div class="dv-side"></div></div>`;
        const $ = (s) => root.querySelector(s);
        const grid = $('.dv-grid'), side = $('.dv-side'), msg = $('.dv-msg'), sqlBox = $('.dv-sql'), sqlText = $('.dv-sql textarea');
        sqlText.value = baseSQL;
        const say = (text, isError) => { msg.textContent = text || ''; msg.classList.toggle('error', !!isError); };
        say(notes.join('\n'), notes.length > 0 && !notes[0].startsWith('Showing'));

        if (manyTables) {
            const select = $('.dv-table');
            select.innerHTML = tables.map((t) => '<option>' + esc(t) + '</option>').join('');
            select.addEventListener('change', () => {
                table = select.value;
                baseSQL = 'SELECT * FROM ' + q(table);
                sqlText.value = baseSQL;
                sort = { column: null, desc: false }; filters = {}; search = '';
                $('.dv-search').value = '';
                run();
            });
        }

        function where(columns) {
            const parts = [];
            const params = [];
            if (search) {
                parts.push('(' + columns.map((c) => 'CAST(' + q(c) + ' AS TEXT) LIKE ?').join(' OR ') + ')');
                columns.forEach(() => params.push('%' + search + '%'));
            }
            for (const [column, raw] of Object.entries(filters)) {
                const text = raw.trim();
                if (!text || !columns.includes(column)) continue;
                const m = text.match(/^(>=|<=|!=|<>|=|>|<)\s*(.*)$/);
                if (/^(null|empty)$/i.test(text)) { parts.push('(' + q(column) + " IS NULL OR " + q(column) + " = '')"); }
                else if (/^!(null|empty)$/i.test(text)) { parts.push('(' + q(column) + " IS NOT NULL AND " + q(column) + " != '')"); }
                else if (m) {
                    const op = m[1] === '<>' ? '!=' : m[1];
                    const value = m[2];
                    const n = Number(value);
                    parts.push(q(column) + ' ' + op + ' ?');
                    params.push(value !== '' && !Number.isNaN(n) ? n : value);
                } else { parts.push('CAST(' + q(column) + ' AS TEXT) LIKE ?'); params.push('%' + text + '%'); }
            }
            return { sql: parts.length ? ' WHERE ' + parts.join(' AND ') : '', params };
        }

        function columnsOf(sql) {
            const stmt = db.prepare('SELECT * FROM (' + sql + ') LIMIT 0');
            const names = stmt.getColumnNames();
            stmt.free();
            return names;
        }

        function run() {
            const sql = (sqlText.value || baseSQL).trim().replace(/;\s*$/, '');
            if (!sql) { grid.innerHTML = ''; $('.dv-count').textContent = 'No tables'; return; }
            try {
                let columns;
                let finalSQL, params = [];
                if (/^\s*(select|with|values|pragma)\b/i.test(sql) && !/^\s*pragma/i.test(sql)) {
                    columns = columnsOf(sql);
                    const w = where(columns);
                    const order = sort.column !== null && columns.includes(sort.column) ? ' ORDER BY ' + q(sort.column) + (sort.desc ? ' DESC' : ' ASC') : '';
                    finalSQL = 'SELECT * FROM (' + sql + ')' + w.sql + order;
                    params = w.params;
                    const total = db.exec('SELECT COUNT(*) FROM (' + sql + ')' + w.sql, params)[0].values[0][0];
                    const stmt = db.prepare(finalSQL + ' LIMIT ' + LIMIT, params);
                    const rows = [];
                    while (stmt.step()) rows.push(stmt.get());
                    stmt.free();
                    result = { columns, rows, total, truncated: total > LIMIT };
                } else {
                    // A statement that changes the in-memory copy (CREATE VIEW, UPDATE…) or a PRAGMA.
                    const out = db.exec(sql);
                    const last = out[out.length - 1];
                    result = last ? { columns: last.columns, rows: last.values, total: last.values.length, truncated: false }
                                  : { columns: [], rows: [], total: 0, truncated: false };
                    say('Done. Changes stay in this view only; the file is not modified.');
                }
                selected = -1;
                render();
                if (!msg.classList.contains('error') && /^\s*(select|with|values)\b/i.test(sql)) say(notes.join('\n'));
            } catch (error) {
                say('SQL error: ' + (error.message || error), true);
            }
        }

        function render() {
            const { columns, rows, total, truncated } = result;
            $('.dv-count').textContent = fmtCount(total) + ' rows' + (truncated ? ' (first ' + fmtCount(LIMIT) + ' shown)' : '') + ' · ' + columns.length + ' columns' + (info2 ? ' · ' + info2 : '');
            const head = '<tr>' + '<th class="dv-rownum">#</th>' + columns.map((c, i) =>
                '<th data-col="' + i + '" title="' + esc(c) + ' — click to sort">' + esc(c) + (sort.column === c ? (sort.desc ? ' ▼' : ' ▲') : '') + '</th>').join('') + '</tr>'
                + '<tr class="dv-filters"><th class="dv-rownum"></th>' + columns.map((c, i) =>
                '<th><input data-col="' + i + '" placeholder="filter" title="text, =x, >10, <=5, !=x, null, !null" value="' + esc(filters[c] || '') + '"></th>').join('') + '</tr>';
            grid.innerHTML = '<table><thead>' + head + '</thead><tbody></tbody></table>';
            const tbody = grid.querySelector('tbody');
            const paint = () => {
                const top = Math.max(0, Math.floor(grid.scrollTop / ROW) - 20);
                const count = Math.ceil(grid.clientHeight / ROW) + 40;
                const end = Math.min(rows.length, top + count);
                let html = '<tr style="height:' + (top * ROW) + 'px"></tr>';
                for (let r = top; r < end; r++) {
                    html += '<tr data-row="' + r + '"' + (r === selected ? ' class="sel"' : '') + '><td class="dv-rownum">' + (r + 1) + '</td>';
                    const row = rows[r];
                    for (let c = 0; c < columns.length; c++) {
                        const v = row[c];
                        const cls = (v === null ? 'null' : typeof v === 'number' ? 'num' : '') + (r === selected && c === currentColumn ? ' cur' : '');
                        html += '<td class="' + cls + '">' + (v === null ? 'null' : esc(v)) + '</td>';
                    }
                    html += '</tr>';
                }
                html += '<tr style="height:' + ((rows.length - end) * ROW) + 'px"></tr>';
                tbody.innerHTML = html;
            };
            grid.onscroll = paint;
            paint();
            grid.querySelectorAll('thead tr:first-child th[data-col]').forEach((th) => th.addEventListener('click', () => {
                const name = columns[+th.dataset.col];
                if (sort.column !== name) sort = { column: name, desc: false };
                else if (!sort.desc) sort.desc = true;
                else sort = { column: null, desc: false };
                currentColumn = +th.dataset.col;
                run();
            }));
            grid.querySelectorAll('thead input').forEach((input) => {
                input.addEventListener('keydown', (e) => { if (e.key === 'Enter') { filters[columns[+input.dataset.col]] = input.value; run(); } });
                input.addEventListener('change', () => { filters[columns[+input.dataset.col]] = input.value; run(); });
            });
            tbody.onclick = (e) => {
                const td = e.target.closest('td');
                const tr = e.target.closest('tr[data-row]');
                if (!tr) return;
                selected = +tr.dataset.row;
                currentColumn = td ? td.cellIndex - 1 : -1;
                paint();
                if (side.classList.contains('visible')) showSide();
            };
            tbody.ondblclick = () => { side.dataset.mode = 'record'; side.classList.add('visible'); showSide(); };
        }

        function showSide() {
            const mode = side.dataset.mode || 'stats';
            const { columns, rows } = result;
            if (mode === 'record') {
                if (selected < 0) { side.innerHTML = '<h4>Row</h4><p>Select a row.</p>'; return; }
                const row = rows[selected];
                side.innerHTML = '<h4>Row ' + (selected + 1) + '</h4><table>' + columns.map((c, i) => {
                    let v = row[i];
                    if (typeof v === 'string' && /^[\[{]/.test(v)) { try { v = JSON.stringify(JSON.parse(v), null, 2); } catch (e) { /* not JSON */ } }
                    return '<tr><td><b>' + esc(c) + '</b></td><td><pre>' + (v === null ? '<i>null</i>' : esc(v)) + '</pre></td></tr>';
                }).join('') + '</table>';
            } else if (mode === 'schema') {
                side.innerHTML = isSQLite ? sqliteSchema() : (parquetDetails || '');
            } else {
                const column = columns[currentColumn >= 0 ? currentColumn : 0];
                if (!column) { side.innerHTML = '<h4>Column stats</h4><p>No column.</p>'; return; }
                const sql = (sqlText.value || baseSQL).trim().replace(/;\s*$/, '');
                const w = where(columns);
                const from = '(SELECT * FROM (' + sql + ')' + w.sql + ')';
                const c = q(column);
                try {
                    const s = db.exec('SELECT COUNT(*), COUNT(' + c + '), COUNT(DISTINCT ' + c + '), MIN(' + c + '), MAX(' + c + '), AVG(CASE WHEN typeof(' + c + ") IN ('integer','real') THEN " + c + ' END), SUM(CASE WHEN typeof(' + c + ") IN ('integer','real') THEN " + c + ' END) FROM ' + from, w.params)[0].values[0];
                    const top = db.exec('SELECT ' + c + ', COUNT(*) AS n FROM ' + from + ' GROUP BY ' + c + ' ORDER BY n DESC LIMIT 12', w.params)[0];
                    const line = (k, v) => '<tr><td>' + k + '</td><td>' + (v === null || v === undefined ? '—' : esc(typeof v === 'number' ? +v.toFixed(6) : v)) + '</td></tr>';
                    side.innerHTML = '<h4>' + esc(column) + '</h4><table>' + line('Rows', s[0]) + line('Non-null', s[1]) + line('Nulls', s[0] - s[1]) + line('Distinct', s[2])
                        + line('Min', s[3]) + line('Max', s[4]) + line('Average', s[5]) + line('Sum', s[6]) + '</table>'
                        + '<h4>Most common</h4><table>' + (top ? top.values.map((r) => line(r[0] === null ? '<i>null</i>' : esc(r[0]), r[1])).join('') : '') + '</table>'
                        + '<p style="color:var(--text-secondary)">Click a column header or cell to choose the column.</p>';
                } catch (error) { side.innerHTML = '<p>' + esc(error.message) + '</p>'; }
            }
        }

        function sqliteSchema() {
            const rows = db.exec("SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name")[0];
            return '<h4>Schema</h4>' + (rows ? rows.values.map((r) => '<p><b>' + esc(r[0]) + ' ' + esc(r[1]) + '</b></p><pre>' + esc(r[2] || '') + '</pre>').join('') : '<p>Empty database.</p>');
        }

        function toDelimited(sep) {
            const { columns, rows } = result;
            const cell = (v) => {
                if (v === null || v === undefined) return '';
                const s = String(v);
                if (sep === '\t') return s.replace(/[\t\n\r]/g, ' ');
                return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
            };
            return [columns.map(cell).join(sep)].concat(rows.map((r) => r.map(cell).join(sep))).join('\n') + '\n';
        }

        $('.dv-search').addEventListener('input', (e) => { search = e.target.value; clearTimeout(run.t); run.t = setTimeout(run, 200); });
        $('.dv-sqlbtn').addEventListener('click', () => { sqlBox.classList.toggle('visible'); $('.dv-sqlbtn').classList.toggle('on', sqlBox.classList.contains('visible')); if (sqlBox.classList.contains('visible')) sqlText.focus(); });
        $('.dv-run').addEventListener('click', () => { sort = { column: null, desc: false }; run(); });
        $('.dv-reset').addEventListener('click', () => { sqlText.value = baseSQL; sort = { column: null, desc: false }; filters = {}; search = ''; $('.dv-search').value = ''; run(); });
        sqlText.addEventListener('keydown', (e) => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); sort = { column: null, desc: false }; run(); } });
        const toggleSide = (mode) => {
            const open = side.classList.contains('visible') && side.dataset.mode === mode;
            side.dataset.mode = mode;
            side.classList.toggle('visible', !open);
            if (!open) showSide();
        };
        $('.dv-stats').addEventListener('click', () => toggleSide('stats'));
        if ($('.dv-schema')) $('.dv-schema').addEventListener('click', () => toggleSide('schema'));
        $('.dv-export').addEventListener('click', () => {
            const blob = new Blob([toDelimited(',')], { type: 'text/csv' });
            const a = document.createElement('a');
            a.href = URL.createObjectURL(blob);
            a.download = info.name.replace(/\.[^.]+$/, '') + '-export.csv';
            a.click();
            setTimeout(() => URL.revokeObjectURL(a.href), 5000);
        });
        $('.dv-copy').addEventListener('click', () => navigator.clipboard.writeText(toDelimited('\t')).then(() => say('Copied ' + fmtCount(result.rows.length) + ' rows.')));
        root.addEventListener('keydown', (e) => {
            if ((e.metaKey || e.ctrlKey) && e.key === 'c' && selected >= 0 && !/INPUT|TEXTAREA/.test(document.activeElement.tagName)) {
                const row = result.rows[selected];
                navigator.clipboard.writeText(currentColumn >= 0 ? String(row[currentColumn] ?? '') : row.map((v) => v ?? '').join('\t'));
                e.preventDefault();
            }
        });
        root.tabIndex = -1;

        run();
        return {
            destroy() { try { db.close(); } catch (e) { /* already closed */ } },
            reload: null, // tables are read once; reopen the tab to read changes
        };
    }

    /** An Excel workbook (xlsx): every sheet as rows of objects, the first row as the header when it
     *  is all text; dates by their cell format. */
    function readWorkbook(bytes, lib) {
        const files = lib.unzip(bytes);
        const xml = (path) => files[path] ? new DOMParser().parseFromString(lib.text(files[path]), 'application/xml') : null;
        const byTag = (node, tag) => node ? Array.from(node.getElementsByTagNameNS('*', tag)) : [];
        const shared = byTag(xml('xl/sharedStrings.xml'), 'si').map((si) => byTag(si, 't').map((t) => t.textContent).join(''));
        // Number formats that are dates: built-in ids and custom codes with d/m/y outside brackets and quotes.
        const styles = xml('xl/styles.xml');
        const custom = {};
        byTag(styles, 'numFmt').forEach((f) => { custom[f.getAttribute('numFmtId')] = f.getAttribute('formatCode') || ''; });
        const cellXfs = styles ? byTag(byTag(styles, 'cellXfs')[0], 'xf') : [];
        const isDateStyle = cellXfs.map((xf) => {
            const id = +xf.getAttribute('numFmtId');
            if ((id >= 14 && id <= 22) || (id >= 45 && id <= 47)) return true;
            const code = (custom[id] || '').replace(/"[^"]*"|\[[^\]]*\]/g, '');
            return /[dy]/i.test(code) || /m{1,4}.*[ds]|[hd].*m/i.test(code);
        });
        const toDate = (serial) => {
            const ms = Math.round((serial - 25569) * 86400000);
            const d = new Date(ms);
            return serial % 1 === 0 ? d.toISOString().slice(0, 10) : d.toISOString().replace('T', ' ').slice(0, 19);
        };
        const rels = {};
        byTag(xml('xl/_rels/workbook.xml.rels'), 'Relationship').forEach((r) => { rels[r.getAttribute('Id')] = r.getAttribute('Target'); });
        const column = (ref) => { let n = 0; for (const ch of ref.replace(/\d+/g, '')) n = n * 26 + ch.charCodeAt(0) - 64; return n - 1; };
        return byTag(xml('xl/workbook.xml'), 'sheet').map((sheet) => {
            const rid = sheet.getAttribute('r:id') || sheet.getAttributeNS('http://schemas.openxmlformats.org/officeDocument/2006/relationships', 'id');
            let target = rels[rid] || '';
            target = target.startsWith('/') ? target.slice(1) : 'xl/' + target.replace(/^\.\//, '');
            const grid = [];
            byTag(xml(target), 'row').forEach((row) => {
                const cells = [];
                byTag(row, 'c').forEach((c) => {
                    const type = c.getAttribute('t');
                    const v = byTag(c, 'v')[0];
                    let value = null;
                    if (type === 's') value = v ? shared[+v.textContent] : null;
                    else if (type === 'inlineStr') value = byTag(c, 't').map((t) => t.textContent).join('');
                    else if (type === 'b') value = v ? (v.textContent === '1') : null;
                    else if (type === 'str' || type === 'e') value = v ? v.textContent : null;
                    else if (v) { const n = Number(v.textContent); value = isDateStyle[+c.getAttribute('s') || 0] ? toDate(n) : n; }
                    cells[column(c.getAttribute('r') || 'A')] = value;
                });
                grid[(+row.getAttribute('r') || grid.length + 1) - 1] = cells;
            });
            const rows = grid.filter(Boolean);
            const width = rows.reduce((m, r) => Math.max(m, r.length), 0);
            const letters = (i) => { let s = ''; i++; while (i > 0) { const m = (i - 1) % 26; s = String.fromCharCode(65 + m) + s; i = Math.floor((i - m) / 26); } return s; };
            const first = rows[0] || [];
            const header = first.length && first.every((v) => typeof v === 'string' && v.trim()) && new Set(first).size === first.length;
            const names = Array.from({ length: width }, (_, i) => header && first[i] ? first[i] : letters(i));
            const objects = (header ? rows.slice(1) : rows).map((r) => { const o = {}; names.forEach((n, i) => { o[n] = r[i] === undefined ? null : r[i]; }); return o; });
            return { name: sheet.getAttribute('name') || 'Sheet', rows: objects };
        });
    }

    function describeParquet(metadata, lib) {
        const schema = lib.parquet.schema(metadata);
        const codecs = new Set();
        metadata.row_groups.forEach((g) => g.columns.forEach((c) => c.meta_data && codecs.add(c.meta_data.codec)));
        const fields = (schema.children || []).map((child) => {
            const el = child.element;
            const type = el.logical_type ? (el.logical_type.type || JSON.stringify(el.logical_type)) : el.converted_type || el.type || (child.children && child.children.length ? 'group' : '');
            return '<tr><td>' + esc(el.name) + '</td><td>' + esc(String(type)) + (el.repetition_type === 'OPTIONAL' ? ' · nullable' : el.repetition_type === 'REPEATED' ? ' · repeated' : '') + '</td></tr>';
        }).join('');
        const kv = (metadata.key_value_metadata || []).filter((e) => e.key !== 'ARROW:schema').map((e) => '<tr><td>' + esc(e.key) + '</td><td><pre>' + esc(String(e.value || '').slice(0, 2000)) + '</pre></td></tr>').join('');
        return '<h4>Parquet</h4><table>'
            + '<tr><td>Rows</td><td>' + fmtCount(Number(metadata.num_rows)) + '</td></tr>'
            + '<tr><td>Row groups</td><td>' + metadata.row_groups.length + '</td></tr>'
            + '<tr><td>Compression</td><td>' + esc([...codecs].join(', ') || '—') + '</td></tr>'
            + '<tr><td>Format version</td><td>' + esc(String(metadata.version)) + '</td></tr>'
            + '<tr><td>Created by</td><td>' + esc(metadata.created_by || '—') + '</td></tr></table>'
            + '<h4>Columns</h4><table>' + fields + '</table>' + (kv ? '<h4>Metadata</h4><table>' + kv + '</table>' : '');
    }

    // ------------------------------------------------------------------ Logs

    const LEVELS = ['fatal', 'error', 'warn', 'info', 'debug', 'trace', 'other'];
    const LEVEL_WORDS = /\b(FATAL|CRITICAL|CRIT|EMERG(?:ENCY)?|ALERT|ERROR|ERR|SEVERE|WARN(?:ING)?|NOTICE|INFO|DEBUG|DBG|TRACE|VERBOSE)\b/i;
    const TIMESTAMP = /^(\[?\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?\]?|\[?\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2}[^\]]*\]?|\w{3} [ \d]\d \d{2}:\d{2}:\d{2}|\d{2}:\d{2}:\d{2}(?:[.,]\d+)?)/;

    function levelOf(word) {
        const w = word.toLowerCase();
        if (/fatal|crit|emerg|alert/.test(w)) return 'fatal';
        if (/err|severe/.test(w)) return 'error';
        if (/warn/.test(w)) return 'warn';
        if (/info|notice/.test(w)) return 'info';
        if (/debug|dbg/.test(w)) return 'debug';
        if (/trace|verbose/.test(w)) return 'trace';
        return 'other';
    }

    /** Lines with their level (JSON logs by their level field; stack traces inherit). */
    function analyseLog(text) {
        const raw = text.split(/\r?\n/);
        if (raw.length && raw[raw.length - 1] === '') raw.pop();
        const lines = new Array(raw.length);
        let previous = 'other';
        for (let i = 0; i < raw.length; i++) {
            const t = raw[i];
            let level = null;
            if (t.charCodeAt(0) === 123 /* { */) {
                try {
                    const o = JSON.parse(t);
                    const v = o.level ?? o.severity ?? o.lvl ?? o.levelname ?? o.log_level ?? (o.log && o.log.level);
                    if (typeof v === 'string') level = levelOf(v);
                    else if (typeof v === 'number') level = v >= 60 ? 'fatal' : v >= 50 ? 'error' : v >= 40 ? 'warn' : v >= 30 ? 'info' : v >= 20 ? 'debug' : 'trace';
                } catch (e) { /* not JSON */ }
            }
            if (!level) {
                const m = t.slice(0, 200).match(LEVEL_WORDS);
                if (m) level = levelOf(m[1]);
                else if (/^\s+(at |\.\.\.|Caused by)|^\s{2,}\S|^Traceback|^\s*File "/.test(t)) level = previous; // continuation
                else level = 'other';
            }
            previous = level;
            lines[i] = { text: t, level };
        }
        return lines;
    }

    function LogViewer(root, name, bytes) {
        let lines = analyseLog(decodeText(bytes));
        const show = { fatal: true, error: true, warn: true, info: true, debug: true, trace: true, other: true };
        let query = '', regex = false, caseSensitive = false, onlyMatches = false, wrap = false, follow = false;
        let visible = [];     // indices into lines
        let matches = [];     // positions in `visible` that match
        let currentMatch = -1, cursor = -1;
        const H = 18;

        root.innerHTML = `
          <div class="dv-bar">
            <span class="dv-title">${esc(name)}</span><span class="dv-meta dv-count"></span>
            <span class="dv-level"></span>
            <span class="dv-spacer"></span>
            <input type="search" class="dv-q" placeholder="Search (⌘F)">
            <button class="dv-btn dv-re" title="Regular expression">.*</button>
            <button class="dv-btn dv-case" title="Match case">Aa</button>
            <button class="dv-btn dv-only" title="Show only matching lines">Only matches</button>
            <button class="dv-btn dv-prev" title="Previous match (⇧↩)">↑</button>
            <button class="dv-btn dv-next" title="Next match (↩)">↓</button>
            <span class="dv-meta dv-mcount"></span>
            <button class="dv-btn dv-err" title="Next error or fatal line">Next error</button>
            <button class="dv-btn dv-wrap">Wrap</button>
            <button class="dv-btn dv-follow" title="Follow the end of the file as it grows">Follow</button>
          </div>
          <div class="dv-msg"></div>
          <div class="dv-body"><div class="dv-log"></div><div class="dv-side"></div></div>`;
        const $ = (s) => root.querySelector(s);
        const view = $('.dv-log'), side = $('.dv-side'), msg = $('.dv-msg');

        function pattern() {
            if (!query) return null;
            try { return new RegExp(regex ? query : query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), caseSensitive ? 'g' : 'gi'); }
            catch (e) { msg.textContent = 'Regular expression: ' + e.message; msg.classList.add('error'); return null; }
        }

        function levelBar() {
            const counts = {};
            LEVELS.forEach((l) => counts[l] = 0);
            lines.forEach((l) => counts[l.level]++);
            $('.dv-level').innerHTML = LEVELS.filter((l) => counts[l] > 0).map((l) =>
                '<button class="dv-btn' + (show[l] ? ' on' : '') + '" data-level="' + l + '">' + l[0].toUpperCase() + l.slice(1) + '<span class="n">' + fmtCount(counts[l]) + '</span></button>').join('');
            $('.dv-level').querySelectorAll('button').forEach((b) => b.addEventListener('click', (e) => {
                const l = b.dataset.level;
                if (e.altKey) LEVELS.forEach((x) => show[x] = x === l); else show[l] = !show[l];
                refilter(); levelBar();
            }));
        }

        function refilter(keepScroll) {
            msg.textContent = ''; msg.classList.remove('error');
            const re = pattern();
            visible = [];
            matches = [];
            for (let i = 0; i < lines.length; i++) {
                if (!show[lines[i].level]) continue;
                let hit = false;
                if (re) { re.lastIndex = 0; hit = re.test(lines[i].text); }
                if (onlyMatches && re && !hit) continue;
                if (hit) matches.push(visible.length);
                visible.push(i);
            }
            $('.dv-count').textContent = fmtCount(lines.length) + ' lines' + (visible.length !== lines.length ? ' · ' + fmtCount(visible.length) + ' shown' : '');
            $('.dv-mcount').textContent = re ? fmtCount(matches.length) + ' matches' : '';
            if (currentMatch >= matches.length) currentMatch = -1;
            paint(true);
            if (follow) view.scrollTop = view.scrollHeight;
            else if (!keepScroll && matches.length && re) goMatch(0);
        }

        function highlight(text, re) {
            if (!re) return tsMark(esc(text));
            let out = '', last = 0, m;
            re.lastIndex = 0;
            while ((m = re.exec(text)) && m[0].length) {
                out += esc(text.slice(last, m.index)) + '<mark>' + esc(m[0]) + '</mark>';
                last = m.index + m[0].length;
            }
            return out + esc(text.slice(last));
        }

        function tsMark(html) {
            const m = html.match(TIMESTAMP);
            return m ? '<span class="ts">' + m[0] + '</span>' + html.slice(m[0].length) : html;
        }

        function lineHTML(position) {
            const index = visible[position];
            const line = lines[index];
            return '<div class="ln ' + line.level + (position === cursor ? ' cur' : '') + '" data-pos="' + position + '"><span class="no">' + (index + 1) + '</span><span class="tx">'
                + highlight(line.text.length > 5000 ? line.text.slice(0, 5000) + '…' : line.text, pattern()) + '</span></div>';
        }

        function paint() {
            if (wrap) {
                // Wrapped lines have different heights: render them all (capped).
                const cap = Math.min(visible.length, 20000);
                let html = '';
                for (let p = 0; p < cap; p++) html += lineHTML(p);
                if (visible.length > cap) html += '<div class="ln"><span class="no"></span><span class="tx">… ' + fmtCount(visible.length - cap) + ' more lines: turn Wrap off to see them</span></div>';
                view.innerHTML = html;
                return;
            }
            const top = Math.max(0, Math.floor(view.scrollTop / H) - 30);
            const end = Math.min(visible.length, top + Math.ceil(view.clientHeight / H) + 60);
            let html = '<div style="height:' + (top * H) + 'px"></div>';
            for (let p = top; p < end; p++) html += lineHTML(p);
            html += '<div style="height:' + ((visible.length - end) * H) + 'px"></div>';
            view.innerHTML = html;
        }

        function scrollToPosition(position) {
            cursor = position;
            if (wrap) { paint(); const el = view.querySelector('[data-pos="' + position + '"]'); if (el) el.scrollIntoView({ block: 'center' }); return; }
            view.scrollTop = Math.max(0, position * H - view.clientHeight / 2);
            paint();
        }

        function goMatch(delta) {
            if (!matches.length) return;
            currentMatch = currentMatch < 0 ? (delta >= 0 ? 0 : matches.length - 1) : (currentMatch + delta + matches.length) % matches.length;
            if (delta === 0) currentMatch = 0;
            $('.dv-mcount').textContent = (currentMatch + 1) + ' / ' + fmtCount(matches.length);
            scrollToPosition(matches[currentMatch]);
        }

        function nextError() {
            const start = cursor + 1;
            for (let k = 0; k < visible.length; k++) {
                const p = (start + k) % visible.length;
                const level = lines[visible[p]].level;
                if (level === 'error' || level === 'fatal') { scrollToPosition(p); return; }
            }
            msg.textContent = 'No error lines among those shown.';
        }

        function showLine(position) {
            const line = lines[visible[position]];
            let body = esc(line.text);
            const brace = line.text.indexOf('{');
            if (brace >= 0) { try { body = esc(JSON.stringify(JSON.parse(line.text.slice(brace)), null, 2)); } catch (e) { /* plain text */ } }
            side.innerHTML = '<h4>Line ' + (visible[position] + 1) + ' · ' + line.level + '</h4><pre>' + body + '</pre>';
            side.classList.add('visible');
        }

        view.addEventListener('scroll', () => { if (!wrap) paint(); });
        view.addEventListener('click', (e) => {
            const ln = e.target.closest('.ln[data-pos]');
            if (!ln) return;
            cursor = +ln.dataset.pos;
            paint();
            showLine(cursor);
        });
        const q2 = $('.dv-q');
        q2.addEventListener('input', () => { query = q2.value; currentMatch = -1; clearTimeout(q2.t); q2.t = setTimeout(() => refilter(), 200); });
        q2.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); goMatch(e.shiftKey ? -1 : 1); } });
        const toggle = (sel, get, set) => $(sel).addEventListener('click', () => { set(!get()); $(sel).classList.toggle('on', get()); refilter(true); });
        toggle('.dv-re', () => regex, (v) => regex = v);
        toggle('.dv-case', () => caseSensitive, (v) => caseSensitive = v);
        toggle('.dv-only', () => onlyMatches, (v) => onlyMatches = v);
        $('.dv-prev').addEventListener('click', () => goMatch(-1));
        $('.dv-next').addEventListener('click', () => goMatch(1));
        $('.dv-err').addEventListener('click', nextError);
        $('.dv-wrap').addEventListener('click', () => { wrap = !wrap; view.classList.toggle('wrap', wrap); $('.dv-wrap').classList.toggle('on', wrap); paint(); });
        $('.dv-follow').addEventListener('click', () => { follow = !follow; $('.dv-follow').classList.toggle('on', follow); if (follow) view.scrollTop = view.scrollHeight; });
        const findKey = (e) => {
            if ((e.metaKey || e.ctrlKey) && e.key === 'f' && container.classList.contains('visible')) { e.preventDefault(); e.stopPropagation(); q2.focus(); q2.select(); }
        };
        document.addEventListener('keydown', findKey, true);

        levelBar();
        refilter();
        return {
            reload(next) {
                const atEnd = view.scrollTop + view.clientHeight >= view.scrollHeight - 4;
                lines = analyseLog(decodeText(next));
                levelBar();
                refilter(true);
                if (follow || atEnd) view.scrollTop = view.scrollHeight;
            },
            destroy() { document.removeEventListener('keydown', findKey, true); },
        };
    }

    // Other content types take over the editor area.
    const wrap = (name) => {
        const original = window[name];
        if (typeof original !== 'function') return;
        window[name] = function () { window.leaveDataView(); return original.apply(this, arguments); };
    };
    ['setContent', 'setStructuredContent', 'setCodeContent'].forEach(wrap);
    window.MVDataViewers = { analyseLog, parseText, loadRows, cellValue };
})();
