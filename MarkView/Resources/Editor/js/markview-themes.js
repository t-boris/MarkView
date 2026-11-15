/*
 * MarkView window themes for the web pages (editor, discussion, terminal).
 *
 * A theme is data: one JSON file per theme (MarkView/Resources/Themes/<id>.json, or a person's own file), read by Swift
 * (MarkView/Models/Appearance/ThemeDefinition.swift). This file holds no colours of any theme, only the logic that turns a
 * definition into CSS custom properties on <html>, plus data-preset (the id), data-theme (dark | light, the mode that older
 * selectors still read) and data-accent. Swift sends the definition of the theme in use with every call (window.setTheme(id,
 * accent, definition)) and writes it into the page text as the data-theme-tokens attribute, so the first paint is already right
 * (applyFromDocument runs in <head>). A definition is { id, mode, base: {bg, panel, text, accent}, t, syn, struct, term,
 * mermaid, and for the looks that keep exact values: vars, ownAccentVars, chart }.
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
    // Definitions arrive from Swift and are remembered by id; nothing here names the colours of a theme. `t`, `syn`, `struct` and
    // `term` hold the colours a theme chooses (Swift fills what a file leaves out); everything else is derived below. A theme that
    // keeps exact values (the Classic looks) also carries `vars` (independent of the accent) and `ownAccentVars` (the values that
    // follow the accent, used only while the accent is the theme's own).
    const known = {};
    const FALLBACK = 'classic-dark';

    function define(definition) {
        if (definition && typeof definition.id === 'string' && definition.base && definition.t) known[definition.id] = definition;
    }
    // The definition of `id`; Classic Dark stands in for an id this page was never given.
    function lookup(id) { return known[id] || known[FALLBACK] || null; }

    // Prism, the tree views and the code view all read these; a preset states only what differs from the shared rules.
    function derive(theme, accentInput) {
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
        const s = theme.syn;
        v['--syn-comment'] = s.comment; v['--syn-punct'] = s.punct; v['--syn-property'] = s.property; v['--syn-number'] = s.number;
        v['--syn-string'] = s.string; v['--syn-operator'] = s.operator; v['--syn-func'] = s.func; v['--syn-keyword'] = s.keyword; v['--syn-regex'] = s.regex;
        const u = theme.struct;
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
        const theme = lookup(id);
        if (!theme) return {};
        const accent = parse(accentInput) ? String(accentInput).toLowerCase() : '';
        const v = derive(theme, accent);
        if (theme.vars) {
            Object.assign(v, theme.vars);
            if (!accent) Object.assign(v, theme.ownAccentVars);
            else {
                // A chosen accent on a look with exact values: the accent-following values are computed, the rest stays exact.
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
        const theme = lookup(id);
        if (!theme) return [];
        if (theme.chart) return theme.chart.slice();
        const v = varsFor(id, accentInput), s = theme.syn;
        return [v['--accent-primary'], theme.t.secondary, theme.t.warning, s.func, s.keyword, s.string, theme.t.danger, s.number];
    }

    // The four colours that follow the accent are derived unless the theme states them; a selection the theme states belongs to
    // its own accent, so a chosen accent recomputes it.
    function terminalTheme(id, accentInput) {
        const theme = lookup(id);
        if (!theme) return {};
        const chosen = parse(accentInput);
        const accent = chosen ? String(accentInput).toLowerCase() : theme.base.accent.toLowerCase();
        const dark = theme.mode === 'dark';
        const result = Object.assign({ background: theme.base.bg.toLowerCase(), foreground: theme.base.text.toLowerCase(),
                                       cursor: adjusted(accent, 3, [theme.base.bg.toLowerCase()]),
                                       selectionBackground: mix(theme.base.bg, accent, dark ? 0.38 : 0.24) }, theme.term);
        if (chosen && theme.term.selectionBackground) result.selectionBackground = mix(theme.base.bg, accentInput, 0.38);
        return result;
    }

    // Mermaid: the built-in dark / default themes for a look that asks for them (Classic), the base theme with tokens otherwise.
    function mermaidConfig(id, accentInput) {
        const theme = lookup(id);
        if (!theme) return {};
        if (theme.mermaid === 'builtin') return { theme: theme.mode === 'dark' ? 'dark' : 'default' };
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

    // `definition` (optional) is the theme's data from Swift; it is remembered, so later calls may name the id alone.
    function apply(id, accentInput, definition, doc) {
        define(definition);
        const theme = lookup(id);
        if (!theme) return current();   // no theme data has reached this page yet: nothing to paint with
        id = theme.id;
        doc = doc || root.document;
        const accent = parse(accentInput) ? String(accentInput).toUpperCase() : '';
        const element = doc.documentElement;
        const vars = varsFor(id, accent);
        Object.keys(vars).forEach(function (name) { element.style.setProperty(name, vars[name]); });
        element.setAttribute('data-preset', id);
        element.setAttribute('data-theme', theme.mode);
        if (accent) element.setAttribute('data-accent', accent); else element.removeAttribute('data-accent');
        if (doc === root.document) {
            state.id = id; state.accent = accent;
            try { root.dispatchEvent(new root.CustomEvent('markview-theme', { detail: current() })); } catch (e) { /* no window */ }
        }
        return current();
    }

    // Reads the attributes Swift wrote into the page text (the id, the accent and the theme's data); call from <head> so the
    // first paint is right.
    function applyFromDocument() {
        const element = root.document.documentElement;
        let definition = null;
        try { definition = JSON.parse(element.getAttribute('data-theme-tokens') || 'null'); } catch (e) { /* unreadable: no data */ }
        return apply(element.getAttribute('data-preset') || FALLBACK, element.getAttribute('data-accent') || '', definition);
    }

    function current() {
        const theme = known[state.id];
        if (!theme) return { id: state.id, mode: 'dark', accent: '', override: '', isDark: true };
        return { id: state.id, mode: theme.mode, accent: state.accent || theme.base.accent.toUpperCase(), override: state.accent,
                 isDark: theme.mode === 'dark' };
    }

    // A token of the current appearance, for scripts that draw on canvases or build SVG.
    function token(name) {
        const applied = root.document && root.document.documentElement.style.getPropertyValue(name).trim();
        return applied || varsFor(state.id, state.accent)[name];
    }

    const api = { ids: function () { return Object.keys(known); }, themes: known, define: define, apply: apply,
                  applyFromDocument: applyFromDocument, current: current, token: token,
                  varsFor: varsFor, terminalTheme: terminalTheme, mermaidConfig: mermaidConfig, chartPalette: chartPalette,
                  mermaid: function () { return mermaidConfig(state.id, state.accent); }, signature: signature,
                  color: { parse: parse, hex: hex, luminance: luminance, contrast: contrast, mix: mix, rgba: rgba, adjusted: adjusted, readableText: readableText } };
    root.MarkViewThemes = api;
    if (typeof module !== 'undefined' && module.exports) module.exports = api;
    if (root.document && root.document.documentElement) {
        try { applyFromDocument(); } catch (e) {}
    }
})(typeof window !== 'undefined' ? window : globalThis);
