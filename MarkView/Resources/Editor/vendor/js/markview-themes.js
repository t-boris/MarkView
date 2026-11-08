/*
 * MarkView window themes for the web pages (editor, discussion, terminal).
 *
 * One file holds the tokens of the six appearances: classic-dark and classic-light (the look before themes,
 * kept value for value, DEC-004) and the presets darcula, midnight, graphite and paper (DEC-003). Swift sends
 * only an appearance id and the accent the window uses; this file turns them into CSS custom properties on
 * <html>, plus data-preset (the id), data-theme (dark | light, the mode that older selectors still read) and
 * data-accent. Swift rewrites those three attributes in the page text so the first paint is already right
 * (applyFromDocument runs in <head>); later changes arrive as window.setTheme(id, accent).
 *
 * The base object on the first line of each appearance repeats the colours of the native palette
 * (MarkView/Models/AppTheme.swift); tools/tests/theme-web-tests.sh compares both sides.
 */
(function (root) {
    'use strict';

    // ---- colour helpers (the same rules as ThemeColor in AppTheme.swift) --------------------------------------------
    function parse(hex) {
        const m = /^#?([0-9a-f]{6})$/i.exec(String(hex || '').trim());
        if (!m) return null;
        const n = parseInt(m[1], 16);
        return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
    }
    function hex(rgb) {
        return '#' + rgb.map(function (c) { return ('0' + Math.max(0, Math.min(255, Math.round(c))).toString(16)).slice(-2); }).join('');
    }
    function luminance(h) {
        const c = parse(h).map(function (v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
    }
    function contrast(a, b) {
        const x = luminance(a), y = luminance(b);
        return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
    }
    function mix(a, b, t) {
        const p = parse(a), q = parse(b);
        return hex(p.map(function (v, i) { return v + (q[i] - v) * t; }));
    }
    function rgba(h, alpha) {
        const c = parse(h);
        return 'rgba(' + c[0] + ', ' + c[1] + ', ' + c[2] + ', ' + alpha + ')';
    }
    // Black or white, whichever reads better on `h`.
    function readableText(h) { return contrast(h, '#000000') >= contrast(h, '#ffffff') ? '#000000' : '#ffffff'; }
    // `h` lightened (on dark backgrounds) or darkened (on light ones) until it reaches `target` against every background.
    function adjusted(h, target, backgrounds) {
        function ok(c) { return backgrounds.every(function (b) { return contrast(c, b) >= target; }); }
        if (ok(h)) return h;
        const average = backgrounds.reduce(function (s, b) { return s + luminance(b); }, 0) / backgrounds.length;
        const end = average < 0.4 ? '#ffffff' : '#000000';
        let fraction = 0;
        while (fraction < 1) {
            fraction = Math.min(fraction + 0.02, 1);
            const candidate = mix(h, end, fraction);
            if (ok(candidate)) return candidate;
        }
        return end;
    }

    // ---- the appearances ------------------------------------------------------------------------------------------
    // `t` holds the colours an appearance chooses; everything else is derived below. Classic appearances also carry
    // `exact` (every value the page had before themes, independent of the accent) and `exactAccent` (the values that
    // follow the accent, used only while the accent is the appearance's own).
    const THEMES = {
        'classic-dark': { base: { bg: '#1E1E1E', panel: '#252526', text: '#D4D4D4', accent: '#569CD6' },
            mode: 'dark', classic: true,
            t: { tertiary: '#2d2d30', textSecondary: '#808080', textTertiary: '#6a6a6a', border: '#3c3c3c', borderLight: '#333333',
                 secondary: '#4ec9b0', danger: '#f44747', success: '#4ec9b0', warning: '#ce9178', hover: '#37373d' },
            exact: {
                '--bg-primary': '#1e1e1e', '--bg-secondary': '#252526', '--bg-tertiary': '#2d2d30',
                '--dc-bg': '#1e1e1e', '--dc-fg': '#d4d4d4', '--dc-dim': '#808080', '--dc-card': '#252526', '--dc-border': '#3c3c3c',
                '--dc-user': '#2a3a4d', '--dc-code': '#2d2d30', '--dc-error': '#f14c4c', '--chart-text': '#d4d4d4', '--chart-grid': '#3c3c3c',
                '--text-primary': '#d4d4d4', '--text-secondary': '#808080', '--text-tertiary': '#6a6a6a',
                '--border-color': '#3c3c3c', '--border-color-light': '#333333',
                '--accent-secondary': '#4ec9b0', '--accent-tertiary': '#f44747', '--accent-warning': '#ce9178',
                '--accent-success': '#4ec9b0', '--accent-danger': '#f44747', '--on-danger': '#ffffff',
                '--code-bg': '#1e1e1e', '--code-text': '#d4d4d4', '--code-border': '#3c3c3c',
                '--shadow-sm': '0 1px 2px rgba(0, 0, 0, 0.3)', '--shadow-md': '0 2px 4px rgba(0, 0, 0, 0.4)', '--shadow-lg': '0 4px 12px rgba(0, 0, 0, 0.5)',
                '--toolbar-text': '#b0b0b0', '--toolbar-text-hover': '#d4d4d4', '--toolbar-hover-bg': '#37373d', '--toolbar-sep': '#3c3c3c',
                '--mode-label': '#6a6a6a', '--float-bg': '#2d2d30', '--float-border': '#3c3c3c', '--float-text': '#d4d4d4',
                '--float-hover': '#37373d', '--float-sep': '#3c3c3c', '--scroll-thumb': '#3c3c3c', '--slider-track': '#3c3c3c',
                '--pre-bg': '#282c34', '--pre-border': '#3a3f4b', '--pre-text': '#abb2bf', '--h2-color': '#9cdcfe', '--h3-color': '#9cdcfe',
                '--link-underline': 'rgba(77, 166, 255, 0.3)', '--dim-opacity': '0.7', '--code-shadow': '0 1px rgba(0, 0, 0, 0.3)', '--line-numbers': '#999999',
                '--rm-active-bg': '#264f78', '--rm-danger-bg': '#a1260d', '--on-rm-danger': '#ffffff',
                '--cv-edge-color': '#7a7a7a', '--cv-node-bg': 'rgba(37, 37, 38, 0.92)', '--cv-node-border': '#4a4a4a', '--cv-group-label': '#b8b8b8', '--cv-grid-dot': 'rgba(255, 255, 255, 0.055)',
                '--syn-comment': '#8292a2', '--syn-punct': '#f8f8f2', '--syn-property': '#f92672', '--syn-number': '#ae81ff',
                '--syn-string': '#a6e22e', '--syn-operator': '#f8f8f2', '--syn-func': '#e6db74', '--syn-keyword': '#66d9ef', '--syn-regex': '#fd971f',
                '--struct-key': '#9cdcfe', '--struct-string': '#ce9178', '--struct-number': '#b5cea8', '--struct-boolean': '#569cd6',
                '--struct-null': '#6a737d', '--struct-bracket': '#808080', '--struct-tag': '#569cd6', '--struct-attr-name': '#9cdcfe',
                '--struct-attr-value': '#ce9178', '--struct-comment': '#6a9955', '--struct-count': '#6a737d', '--struct-hover': 'rgba(255, 255, 255, 0.04)',
                '--ok-text': '#3c9a5f', '--warn-text': '#c9892a', '--bad-text': '#d9534f',
                '--arch-bg': '#17191c', '--arch-node': '#23272c', '--arch-box-line': '#353b44', '--arch-line': '#3a4049', '--arch-text': '#e3e6e9', '--arch-mute': '#8d949e', '--arch-ok': '#4cc38a', '--arch-warn': '#e2ab4a', '--arch-bad': '#f07a73', '--arch-info': '#6cb6ff',
                '--cm-bg': '#17191c', '--cm-fg': '#d8dce1', '--cm-gutter': '#6b727c', '--cm-active': '#1f2327', '--cm-sel': '#2b3a5c',
                '--cm-kw': '#c792ea', '--cm-str': '#9ece6a', '--cm-num': '#ff9e64', '--cm-com': '#6b7480', '--cm-fn': '#7aa2f7',
                '--cm-type': '#2ac3de', '--cm-prop': '#a9b1d6', '--cm-op': '#89ddff', '--cm-tag': '#f7768e', '--cm-marker': '#2c3035',
                '--cm-match': '#3b4261', '--cm-flash': '#3a3218' },
            exactAccent: {
                '--accent-primary': '#569cd6', '--accent-info': '#569cd6', '--accent-color': '#569cd6', '--accent': '#4c8dff',
                '--accent-fill': '#569cd6', '--on-accent': '#ffffff', '--selection-bg': 'rgba(38, 79, 120, 0.5)', '--selection-color': '#569cd6',
                '--toolbar-active-bg': '#264f78', '--toolbar-active-text': '#ffffff', '--arch-box': '#7d97ff', '--arch-accent': '#7d97ff', '--dc-accent': '#569cd6',
                '--rm-primary-bg': '#0e639c', '--rm-primary-hover-bg': '#1177bb', '--on-rm-primary': '#ffffff' },
            syn: {},
            term: { background: '#1e1e1e', foreground: '#d4d4d4', cursor: '#aeafad', selectionBackground: '#264f78',
                black: '#000000', red: '#cd3131', green: '#0dbc79', yellow: '#e5e510', blue: '#2472c8', magenta: '#bc3fbc',
                cyan: '#11a8cd', white: '#e5e5e5', brightBlack: '#666666', brightRed: '#f14c4c', brightGreen: '#23d18b',
                brightYellow: '#f5f543', brightBlue: '#3b8eea', brightMagenta: '#d670d6', brightCyan: '#29b8db', brightWhite: '#e5e5e5' } },

        'classic-light': { base: { bg: '#FFFFFF', panel: '#F3F3F3', text: '#1E1E1E', accent: '#569CD6' },
            mode: 'light', classic: true,
            t: { tertiary: '#e8e8e8', textSecondary: '#6e7681', textTertiary: '#8b949e', border: '#d4d4d4', borderLight: '#e1e4e8',
                 secondary: '#22863a', danger: '#cb2431', success: '#22863a', warning: '#b08800', hover: '#e0e0e0' },
            exact: {
                '--bg-primary': '#ffffff', '--bg-secondary': '#f3f3f3', '--bg-tertiary': '#e8e8e8',
                '--dc-bg': '#ffffff', '--dc-fg': '#1f2328', '--dc-dim': '#6e7681', '--dc-card': '#f6f8fa', '--dc-border': '#d0d7de',
                '--dc-user': '#ddf0ff', '--dc-code': '#eef1f4', '--dc-error': '#f14c4c', '--chart-text': '#1f2328', '--chart-grid': '#d0d7de',
                '--text-primary': '#1e1e1e', '--text-secondary': '#6e7681', '--text-tertiary': '#8b949e',
                '--border-color': '#d4d4d4', '--border-color-light': '#e1e4e8',
                '--accent-secondary': '#22863a', '--accent-tertiary': '#cb2431', '--accent-warning': '#b08800',
                '--accent-success': '#22863a', '--accent-danger': '#cb2431', '--on-danger': '#ffffff',
                '--code-bg': '#f6f8fa', '--code-text': '#24292e', '--code-border': '#e1e4e8',
                '--shadow-sm': '0 1px 2px rgba(0, 0, 0, 0.07)', '--shadow-md': '0 2px 4px rgba(0, 0, 0, 0.1)', '--shadow-lg': '0 4px 12px rgba(0, 0, 0, 0.12)',
                '--toolbar-text': '#505050', '--toolbar-text-hover': '#1e1e1e', '--toolbar-hover-bg': '#e0e0e0', '--toolbar-sep': '#d4d4d4',
                '--mode-label': '#6a6a6a', '--float-bg': '#f3f3f3', '--float-border': '#d4d4d4', '--float-text': '#1e1e1e',
                '--float-hover': '#e8e8e8', '--float-sep': '#3c3c3c', '--scroll-thumb': '#c1c1c1', '--slider-track': '#d4d4d4',
                '--pre-bg': '#f6f8fa', '--pre-border': '#e1e4e8', '--pre-text': '#24292e', '--h2-color': '#0550ae', '--h3-color': '#0550ae',
                '--link-underline': 'rgba(0, 102, 204, 0.3)', '--dim-opacity': '0.7', '--code-shadow': '0 1px rgba(0, 0, 0, 0.3)', '--line-numbers': '#999999',
                '--rm-active-bg': '#cfe4f7', '--rm-danger-bg': '#cb2431', '--on-rm-danger': '#ffffff',
                '--cv-edge-color': '#8a8a8a', '--cv-node-bg': 'rgba(255, 255, 255, 0.95)', '--cv-node-border': '#c8c8c8', '--cv-group-label': '#555', '--cv-grid-dot': 'rgba(0, 0, 0, 0.07)',
                '--syn-comment': '#8292a2', '--syn-punct': '#f8f8f2', '--syn-property': '#f92672', '--syn-number': '#ae81ff',
                '--syn-string': '#a6e22e', '--syn-operator': '#f8f8f2', '--syn-func': '#e6db74', '--syn-keyword': '#66d9ef', '--syn-regex': '#fd971f',
                '--struct-key': '#0451a5', '--struct-string': '#a31515', '--struct-number': '#098658', '--struct-boolean': '#0000ff',
                '--struct-null': '#6a737d', '--struct-bracket': '#808080', '--struct-tag': '#800000', '--struct-attr-name': '#e50000',
                '--struct-attr-value': '#0451a5', '--struct-comment': '#6a9955', '--struct-count': '#6a737d', '--struct-hover': 'rgba(0, 0, 0, 0.04)',
                '--ok-text': '#3c9a5f', '--warn-text': '#c9892a', '--bad-text': '#d9534f',
                '--arch-bg': '#fbfbfa', '--arch-node': '#ffffff', '--arch-box-line': '#d4d8de', '--arch-line': '#c3c8cf', '--arch-text': '#1b1e23', '--arch-mute': '#6b717b', '--arch-ok': '#23845a', '--arch-warn': '#b77a12', '--arch-bad': '#c2413b', '--arch-info': '#2f7fd1',
                '--cm-bg': '#fbfbfa', '--cm-fg': '#1b1e23', '--cm-gutter': '#9aa0a8', '--cm-active': '#f1f2f0', '--cm-sel': '#d6e0fb',
                '--cm-kw': '#8a3fb8', '--cm-str': '#2d7d46', '--cm-num': '#b3541e', '--cm-com': '#8a9099', '--cm-fn': '#2b54d9',
                '--cm-type': '#0b7a8a', '--cm-prop': '#3d4450', '--cm-op': '#6b717b', '--cm-tag': '#c2413b', '--cm-marker': '#e3e5e1',
                '--cm-match': '#e4e9fb', '--cm-flash': '#fbefd2' },
            exactAccent: {
                '--accent-primary': '#0366d6', '--accent-info': '#0366d6', '--accent-color': '#569cd6', '--accent': '#4c8dff',
                '--accent-fill': '#0366d6', '--on-accent': '#ffffff', '--selection-bg': 'rgba(3, 102, 214, 0.2)', '--selection-color': '#0366d6',
                '--toolbar-active-bg': '#264f78', '--toolbar-active-text': '#ffffff', '--arch-box': '#2b54d9', '--arch-accent': '#2b54d9', '--dc-accent': '#0969da',
                '--rm-primary-bg': '#0366d6', '--rm-primary-hover-bg': '#0550ae', '--on-rm-primary': '#ffffff' },
            syn: {},
            term: { background: '#ffffff', foreground: '#1f2328', cursor: '#1f2328', selectionBackground: '#add6ff',
                black: '#000000', red: '#cd3131', green: '#00bc00', yellow: '#949800', blue: '#0451a5', magenta: '#bc05bc',
                cyan: '#0598bc', white: '#555555', brightBlack: '#666666', brightRed: '#cd3131', brightGreen: '#14ce14',
                brightYellow: '#b5ba00', brightBlue: '#0451a5', brightMagenta: '#bc05bc', brightCyan: '#0598bc', brightWhite: '#a5a5a5' } },

        'darcula': { base: { bg: '#2B2B2B', panel: '#323232', text: '#E0E0E0', accent: '#E6A15C' },
            mode: 'dark',
            t: { tertiary: '#393939', textSecondary: '#a3a3a3', textTertiary: '#9a9a9a', border: '#484848', borderLight: '#3c3c3c',
                 secondary: '#6dc3d6', danger: '#ff6b68', success: '#8dc278', warning: '#e0884a', hover: '#464646',
                 h2: '#e8bf6a', h3: '#c39bd9', codeBg: '#3c3f41', preBg: '#252525', preBorder: '#3f3f3f', preText: '#dcdcdc' },
            syn: { comment: '#9c9c9c', punct: '#c8c8c8', property: '#e8bf6a', number: '#7fb2d9', string: '#9bc18a', operator: '#d6d6d6',
                   func: '#ffc66d', keyword: '#e8884a', regex: '#6fc1b0' },
            struct: { key: '#e8bf6a', string: '#9bc18a', number: '#7fb2d9', boolean: '#e8884a', null: '#9a9a9a', bracket: '#a3a3a3',
                      tag: '#e8bf6a', attrName: '#c39bd9', attrValue: '#9bc18a', comment: '#9c9c9c', count: '#9a9a9a' },
            term: { black: '#3b3b3b', red: '#ff6b68', green: '#8dc278', yellow: '#e3c86f', blue: '#7fb2d9', magenta: '#c39bd9',
                    cyan: '#6dc3d6', white: '#d0d0d0', brightBlack: '#9c9c9c', brightRed: '#ff8f8d', brightGreen: '#a5d48e',
                    brightYellow: '#f0d98c', brightBlue: '#9cc6e8', brightMagenta: '#d4b3e6', brightCyan: '#8ad6e6', brightWhite: '#ffffff' } },

        'midnight': { base: { bg: '#151C2B', panel: '#1D2738', text: '#E5EBF5', accent: '#79B8FF' },
            mode: 'dark',
            t: { tertiary: '#27344b', textSecondary: '#93a1ba', textTertiary: '#8794ad', border: '#303f5a', borderLight: '#253249',
                 secondary: '#5cd3e6', danger: '#ff7b86', success: '#7fd6a4', warning: '#f2a36b', hover: '#2c3b58',
                 h2: '#8fd0e8', h3: '#b79cff', codeBg: '#27344b', preBg: '#0f1522', preBorder: '#263349', preText: '#d6deeb' },
            syn: { comment: '#8593ae', punct: '#b8c4da', property: '#7fdbca', number: '#f78c6c', string: '#c3e88d', operator: '#89ddff',
                   func: '#82aaff', keyword: '#c792ea', regex: '#ffcb6b' },
            struct: { key: '#82aaff', string: '#c3e88d', number: '#f78c6c', boolean: '#c792ea', null: '#8593ae', bracket: '#93a1ba',
                      tag: '#7fdbca', attrName: '#c792ea', attrValue: '#c3e88d', comment: '#8593ae', count: '#8794ad' },
            term: { black: '#2c3a55', red: '#ff7b86', green: '#7fd6a4', yellow: '#e9d08a', blue: '#79b8ff', magenta: '#b79cff',
                    cyan: '#5cd3e6', white: '#cbd5e6', brightBlack: '#8593ae', brightRed: '#ff9ca4', brightGreen: '#a0e6be',
                    brightYellow: '#f3e0a8', brightBlue: '#9ccbff', brightMagenta: '#cdb8ff', brightCyan: '#8ce3f0', brightWhite: '#ffffff' } },

        'graphite': { base: { bg: '#202124', panel: '#2A2C30', text: '#E8EAED', accent: '#B39DDB' },
            mode: 'dark',
            t: { tertiary: '#33353a', textSecondary: '#9aa0a6', textTertiary: '#8f959b', border: '#40434a', borderLight: '#33353a',
                 secondary: '#78d9ec', danger: '#f28b82', success: '#81c995', warning: '#f6ae5f', hover: '#3e4147',
                 h2: '#aecbfa', h3: '#fdd663', codeBg: '#36383d', preBg: '#1a1b1e', preBorder: '#34363b', preText: '#dadce0' },
            syn: { comment: '#8f959b', punct: '#bdc1c6', property: '#f28b82', number: '#fdd663', string: '#81c995', operator: '#78d9ec',
                   func: '#aecbfa', keyword: '#d7aefb', regex: '#fcad70' },
            struct: { key: '#aecbfa', string: '#81c995', number: '#fdd663', boolean: '#d7aefb', null: '#8f959b', bracket: '#9aa0a6',
                      tag: '#f28b82', attrName: '#fcad70', attrValue: '#81c995', comment: '#8f959b', count: '#8f959b' },
            term: { black: '#3c4043', red: '#f28b82', green: '#81c995', yellow: '#fdd663', blue: '#8ab4f8', magenta: '#d7aefb',
                    cyan: '#78d9ec', white: '#dadce0', brightBlack: '#8f959b', brightRed: '#f6aea9', brightGreen: '#a8dab5',
                    brightYellow: '#fde293', brightBlue: '#aecbfa', brightMagenta: '#e4c7fc', brightCyan: '#a1e4f2', brightWhite: '#ffffff' } },

        'paper': { base: { bg: '#FFFCF5', panel: '#F2EDE3', text: '#292724', accent: '#315E9B' },
            mode: 'light',
            t: { tertiary: '#e8e1d3', textSecondary: '#655f55', textTertiary: '#6c655a', border: '#d6cebe', borderLight: '#e6dfd0',
                 secondary: '#00707e', danger: '#b3261e', success: '#287030', warning: '#a05000', hover: '#ddd5c4',
                 h2: '#7a4a12', h3: '#1f6f6b', codeBg: '#efe8da', preBg: '#f6f1e6', preBorder: '#d6cebe', preText: '#292724' },
            syn: { comment: '#6e675b', punct: '#5c564d', property: '#b03a2e', number: '#9c4a00', string: '#1f6f3a', operator: '#4a4540',
                   func: '#2b5ba8', keyword: '#7b3fa0', regex: '#8a6000' },
            struct: { key: '#2b5ba8', string: '#1f6f3a', number: '#9c4a00', boolean: '#7b3fa0', null: '#6e675b', bracket: '#655f55',
                      tag: '#b03a2e', attrName: '#9c4a00', attrValue: '#1f6f3a', comment: '#6e675b', count: '#6c655a' },
            term: { black: '#292724', red: '#b3261e', green: '#287030', yellow: '#7f6400', blue: '#315e9b', magenta: '#7b3fa0',
                    cyan: '#00707e', white: '#8a8478', brightBlack: '#6c655a', brightRed: '#d0342b', brightGreen: '#2a7e34',
                    brightYellow: '#946f00', brightBlue: '#3d74c0', brightMagenta: '#9650c0', brightCyan: '#07808f', brightWhite: '#a59e90' } }
    };

    const IDS = Object.keys(THEMES);
    const FALLBACK = 'classic-dark';

    // Prism, the tree views and the code view all read these; a preset states only what differs from the shared rules.
    function derive(id, accentInput) {
        const theme = THEMES[id];
        const base = theme.base, t = theme.t, dark = theme.mode === 'dark';
        const bg = base.bg.toLowerCase(), panel = base.panel.toLowerCase(), text = base.text.toLowerCase();
        const accent = (accentInput || base.accent).toLowerCase();
        const readable = adjusted(accent, 4.5, [bg, panel]);
        const fill = accent;
        const onFill = readableText(fill);
        const v = {};
        v['--bg-primary'] = bg; v['--bg-secondary'] = panel; v['--bg-tertiary'] = t.tertiary;
        v['--text-primary'] = text; v['--text-secondary'] = t.textSecondary; v['--text-tertiary'] = t.textTertiary;
        v['--border-color'] = t.border; v['--border-color-light'] = t.borderLight;
        v['--accent-primary'] = readable; v['--accent-info'] = readable; v['--accent-color'] = readable; v['--accent'] = accent;
        v['--accent-fill'] = fill; v['--on-accent'] = onFill; v['--on-danger'] = readableText(t.danger);
        v['--accent-secondary'] = t.secondary; v['--accent-tertiary'] = t.danger; v['--accent-warning'] = t.warning;
        v['--accent-success'] = t.success; v['--accent-danger'] = t.danger;
        v['--code-bg'] = t.codeBg || t.tertiary; v['--code-text'] = text; v['--code-border'] = t.border;
        v['--selection-bg'] = rgba(accent, dark ? 0.34 : 0.22); v['--selection-color'] = readable;
        v['--shadow-sm'] = dark ? '0 1px 2px rgba(0, 0, 0, 0.3)' : '0 1px 2px rgba(0, 0, 0, 0.07)';
        v['--shadow-md'] = dark ? '0 2px 4px rgba(0, 0, 0, 0.4)' : '0 2px 4px rgba(0, 0, 0, 0.1)';
        v['--shadow-lg'] = dark ? '0 4px 12px rgba(0, 0, 0, 0.5)' : '0 4px 12px rgba(0, 0, 0, 0.12)';
        v['--toolbar-text'] = t.textSecondary; v['--toolbar-text-hover'] = text; v['--toolbar-hover-bg'] = t.hover; v['--toolbar-sep'] = t.border;
        v['--toolbar-active-bg'] = fill; v['--toolbar-active-text'] = onFill; v['--mode-label'] = t.textTertiary;
        v['--float-bg'] = t.tertiary; v['--float-border'] = t.border; v['--float-text'] = text; v['--float-hover'] = t.hover; v['--float-sep'] = t.border;
        v['--scroll-thumb'] = t.border; v['--slider-track'] = t.border;
        v['--pre-bg'] = t.preBg; v['--pre-border'] = t.preBorder; v['--pre-text'] = t.preText;
        v['--h2-color'] = t.h2; v['--h3-color'] = t.h3;
        v['--link-underline'] = rgba(accent, 0.3); v['--dim-opacity'] = '1'; v['--code-shadow'] = 'none'; v['--line-numbers'] = t.textTertiary;
        const s = theme.syn || {};
        v['--syn-comment'] = s.comment; v['--syn-punct'] = s.punct; v['--syn-property'] = s.property; v['--syn-number'] = s.number;
        v['--syn-string'] = s.string; v['--syn-operator'] = s.operator; v['--syn-func'] = s.func; v['--syn-keyword'] = s.keyword; v['--syn-regex'] = s.regex;
        const u = theme.struct || {};
        v['--struct-key'] = u.key; v['--struct-string'] = u.string; v['--struct-number'] = u.number; v['--struct-boolean'] = u.boolean;
        v['--struct-null'] = u.null; v['--struct-bracket'] = u.bracket; v['--struct-tag'] = u.tag; v['--struct-attr-name'] = u.attrName;
        v['--struct-attr-value'] = u.attrValue; v['--struct-comment'] = u.comment; v['--struct-count'] = u.count;
        v['--struct-hover'] = dark ? 'rgba(255, 255, 255, 0.04)' : 'rgba(0, 0, 0, 0.04)';
        v['--ok-text'] = t.success; v['--warn-text'] = t.warning; v['--bad-text'] = t.danger;
        v['--rm-active-bg'] = mix(bg, accent, dark ? 0.3 : 0.22); v['--rm-primary-bg'] = fill; v['--rm-primary-hover-bg'] = mix(fill, text, 0.18);
        v['--on-rm-primary'] = onFill; v['--rm-danger-bg'] = t.danger; v['--on-rm-danger'] = readableText(t.danger);
        v['--cv-edge-color'] = t.textTertiary; v['--cv-node-bg'] = rgba(panel, 0.92); v['--cv-node-border'] = t.border;
        v['--cv-group-label'] = t.textSecondary; v['--cv-grid-dot'] = rgba(text, dark ? 0.055 : 0.07);
        // The discussion thread and the charts drawn in it.
        v['--dc-bg'] = bg; v['--dc-fg'] = text; v['--dc-dim'] = t.textSecondary; v['--dc-card'] = panel; v['--dc-border'] = t.border;
        v['--dc-accent'] = readable; v['--dc-user'] = mix(bg, accent, dark ? 0.22 : 0.14); v['--dc-code'] = t.codeBg || t.tertiary;
        v['--dc-error'] = t.danger; v['--chart-text'] = text; v['--chart-grid'] = t.border;
        // The architecture graph.
        v['--arch-bg'] = bg; v['--arch-node'] = panel; v['--arch-box'] = readable; v['--arch-box-line'] = t.border; v['--arch-line'] = t.border;
        v['--arch-text'] = text; v['--arch-mute'] = t.textSecondary; v['--arch-accent'] = readable; v['--arch-ok'] = t.success;
        v['--arch-warn'] = t.warning; v['--arch-bad'] = t.danger; v['--arch-info'] = t.secondary;
        // The code view (CodeMirror) draws on the page background; its token colours are the shared syntax colours.
        v['--cm-bg'] = bg; v['--cm-fg'] = text; v['--cm-gutter'] = t.textTertiary; v['--cm-active'] = panel;
        v['--cm-sel'] = mix(bg, accent, dark ? 0.24 : 0.18); v['--cm-kw'] = s.keyword; v['--cm-str'] = s.string; v['--cm-num'] = s.number;
        v['--cm-com'] = s.comment; v['--cm-fn'] = s.func; v['--cm-type'] = t.secondary; v['--cm-prop'] = s.property; v['--cm-op'] = s.operator;
        v['--cm-tag'] = s.property; v['--cm-marker'] = t.borderLight; v['--cm-match'] = mix(bg, accent, 0.2);
        v['--cm-flash'] = dark ? mix(bg, '#ffd54a', 0.18) : mix(bg, '#ffd54a', 0.35);
        return v;
    }

    // All custom properties of an appearance for an accent ('' / null = the appearance's own).
    function varsFor(id, accentInput) {
        if (!THEMES[id]) id = FALLBACK;
        const theme = THEMES[id];
        const accent = parse(accentInput) ? String(accentInput).toLowerCase() : '';
        const v = derive(id, accent);
        if (theme.classic) {
            Object.assign(v, theme.exact);
            if (!accent) Object.assign(v, theme.exactAccent);
            else {
                // A chosen accent on a classic look: the accent-following values are computed, the rest stays exact.
                v['--link-underline'] = rgba(accent, 0.3);
            }
        }
        // Colours the pages derive from the accent with a fixed alpha (focus ring, revealed line, match highlight).
        const raw = accent || theme.base.accent;
        v['--accent-a15'] = rgba(raw, 0.15); v['--accent-a28'] = rgba(raw, 0.28); v['--accent-a70'] = rgba(raw, 0.7);
        return v;
    }

    // The colours of chart series that the AI did not colour itself.
    function chartPalette(id, accentInput) {
        if (!THEMES[id]) id = FALLBACK;
        const theme = THEMES[id];
        if (theme.classic) return ['#569cd6', '#4ec9b0', '#ce9178', '#dcdcaa', '#c586c0', '#9cdcfe', '#d7ba7d', '#6a9955'];
        const v = varsFor(id, accentInput), s = theme.syn;
        return [v['--accent-primary'], theme.t.secondary, theme.t.warning, s.func, s.keyword, s.string, theme.t.danger, s.number];
    }

    function terminalTheme(id, accentInput) {
        if (!THEMES[id]) id = FALLBACK;
        const theme = THEMES[id];
        if (theme.classic) {
            const copy = Object.assign({}, theme.term);
            if (parse(accentInput)) copy.selectionBackground = mix(theme.base.bg, accentInput, 0.38);
            return copy;
        }
        const accent = parse(accentInput) ? String(accentInput).toLowerCase() : theme.base.accent.toLowerCase();
        const dark = theme.mode === 'dark';
        return Object.assign({ background: theme.base.bg.toLowerCase(), foreground: theme.base.text.toLowerCase(),
                               cursor: adjusted(accent, 3, [theme.base.bg.toLowerCase()]),
                               selectionBackground: mix(theme.base.bg, accent, dark ? 0.38 : 0.24) }, theme.term);
    }

    // Mermaid: the built-in dark / default themes for the classic looks, the base theme with tokens for the presets.
    function mermaidConfig(id, accentInput) {
        if (!THEMES[id]) id = FALLBACK;
        const theme = THEMES[id];
        if (theme.classic) return { theme: theme.mode === 'dark' ? 'dark' : 'default' };
        const v = varsFor(id, accentInput);
        return { theme: 'base', themeVariables: {
            darkMode: theme.mode === 'dark', background: v['--bg-primary'], fontFamily: 'inherit',
            primaryColor: v['--bg-tertiary'], primaryTextColor: v['--text-primary'], primaryBorderColor: v['--accent-primary'],
            secondaryColor: v['--bg-secondary'], tertiaryColor: v['--bg-secondary'], lineColor: v['--text-secondary'],
            textColor: v['--text-primary'], mainBkg: v['--bg-tertiary'], nodeBorder: v['--accent-primary'],
            clusterBkg: v['--bg-secondary'], clusterBorder: v['--border-color'], titleColor: v['--text-primary'],
            edgeLabelBackground: v['--bg-primary'], noteBkgColor: v['--bg-tertiary'], noteTextColor: v['--text-primary'] } };
    }

    // ---- applying -------------------------------------------------------------------------------------------------
    const state = { id: FALLBACK, accent: '' };
    // Identifies the appearance and accent in use, for caches of anything drawn with the theme's colours.
    function signature() { return state.id + '|' + state.accent; }

    function apply(id, accentInput, doc) {
        if (!THEMES[id]) id = FALLBACK;
        doc = doc || root.document;
        const accent = parse(accentInput) ? String(accentInput).toUpperCase() : '';
        const element = doc.documentElement;
        const vars = varsFor(id, accent);
        Object.keys(vars).forEach(function (name) { element.style.setProperty(name, vars[name]); });
        element.setAttribute('data-preset', id);
        element.setAttribute('data-theme', THEMES[id].mode);
        if (accent) element.setAttribute('data-accent', accent); else element.removeAttribute('data-accent');
        if (doc === root.document) {
            state.id = id; state.accent = accent;
            try { root.dispatchEvent(new root.CustomEvent('markview-theme', { detail: current() })); } catch (e) { /* no window */ }
        }
        return current();
    }

    // Reads the attributes Swift wrote into the page text; call from <head> so the first paint is right.
    function applyFromDocument() {
        const element = root.document.documentElement;
        return apply(element.getAttribute('data-preset') || FALLBACK, element.getAttribute('data-accent') || '');
    }

    function current() {
        const theme = THEMES[state.id];
        return { id: state.id, mode: theme.mode, accent: state.accent || theme.base.accent.toUpperCase(), override: state.accent,
                 isDark: theme.mode === 'dark', classic: !!theme.classic };
    }

    // A token of the current appearance, for scripts that draw on canvases or build SVG.
    function token(name) {
        const applied = root.document && root.document.documentElement.style.getPropertyValue(name).trim();
        return applied || varsFor(state.id, state.accent)[name];
    }

    const api = { ids: IDS, themes: THEMES, apply: apply, applyFromDocument: applyFromDocument, current: current, token: token,
                  varsFor: varsFor, terminalTheme: terminalTheme, mermaidConfig: mermaidConfig, chartPalette: chartPalette,
                  mermaid: function () { return mermaidConfig(state.id, state.accent); }, signature: signature,
                  color: { parse: parse, hex: hex, luminance: luminance, contrast: contrast, mix: mix, rgba: rgba, adjusted: adjusted, readableText: readableText } };
    root.MarkViewThemes = api;
    if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
