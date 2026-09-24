// Read-only code viewer for MarkView, bundled to vendor/js/codemirror.bundle.js
// as the global `MVCode`. Languages are bundled statically (no dynamic imports),
// so the viewer works offline inside WKWebView.
import { EditorState, Compartment } from "@codemirror/state";
import { EditorView, lineNumbers, highlightActiveLineGutter, highlightSpecialChars,
         drawSelection, highlightActiveLine, keymap } from "@codemirror/view";
import { foldGutter, codeFolding, foldKeymap, bracketMatching, syntaxHighlighting,
         HighlightStyle, StreamLanguage, indentUnit } from "@codemirror/language";
import { defaultKeymap } from "@codemirror/commands";
import { search, searchKeymap, highlightSelectionMatches, openSearchPanel } from "@codemirror/search";
import { tags as t } from "@lezer/highlight";
import { indentationMarkers } from "@replit/codemirror-indentation-markers";

import { javascript } from "@codemirror/lang-javascript";
import { python } from "@codemirror/lang-python";
import { rust } from "@codemirror/lang-rust";
import { cpp } from "@codemirror/lang-cpp";
import { java } from "@codemirror/lang-java";
import { go } from "@codemirror/lang-go";
import { php } from "@codemirror/lang-php";
import { html } from "@codemirror/lang-html";
import { css } from "@codemirror/lang-css";
import { json } from "@codemirror/lang-json";
import { markdown } from "@codemirror/lang-markdown";
import { sql } from "@codemirror/lang-sql";
import { xml } from "@codemirror/lang-xml";
import { yaml } from "@codemirror/lang-yaml";

import { swift } from "@codemirror/legacy-modes/mode/swift";
import { kotlin, scala, csharp, dart, objectiveC, objectiveCpp } from "@codemirror/legacy-modes/mode/clike";
import { shell } from "@codemirror/legacy-modes/mode/shell";
import { ruby } from "@codemirror/legacy-modes/mode/ruby";
import { lua } from "@codemirror/legacy-modes/mode/lua";
import { dockerFile } from "@codemirror/legacy-modes/mode/dockerfile";
import { toml } from "@codemirror/legacy-modes/mode/toml";
import { perl } from "@codemirror/legacy-modes/mode/perl";
import { r } from "@codemirror/legacy-modes/mode/r";
import { powerShell } from "@codemirror/legacy-modes/mode/powershell";
import { protobuf } from "@codemirror/legacy-modes/mode/protobuf";
import { nginx } from "@codemirror/legacy-modes/mode/nginx";
import { diff } from "@codemirror/legacy-modes/mode/diff";
import { properties } from "@codemirror/legacy-modes/mode/properties";
import { cmake } from "@codemirror/legacy-modes/mode/cmake";
import { haskell } from "@codemirror/legacy-modes/mode/haskell";
import { clojure } from "@codemirror/legacy-modes/mode/clojure";
import { erlang } from "@codemirror/legacy-modes/mode/erlang";
import { groovy } from "@codemirror/legacy-modes/mode/groovy";
import { julia } from "@codemirror/legacy-modes/mode/julia";
import { oCaml, fSharp } from "@codemirror/legacy-modes/mode/mllike";
import { sass } from "@codemirror/legacy-modes/mode/sass";
import { crystal } from "@codemirror/legacy-modes/mode/crystal";

const legacy = (mode) => () => StreamLanguage.define(mode);

// Language ids are chosen on the Swift side (FileType.codeLanguage).
const languages = {
  javascript: () => javascript({ jsx: true }),
  typescript: () => javascript({ jsx: true, typescript: true }),
  python: () => python(), rust: () => rust(), cpp: () => cpp(), c: () => cpp(),
  java: () => java(), go: () => go(), php: () => php(), html: () => html(),
  css: () => css(), scss: () => css(), less: () => css(), json: () => json(),
  markdown: () => markdown(), sql: () => sql(), xml: () => xml(), yaml: () => yaml(),
  swift: legacy(swift), kotlin: legacy(kotlin), scala: legacy(scala), csharp: legacy(csharp),
  dart: legacy(dart), objectivec: legacy(objectiveC), objectivecpp: legacy(objectiveCpp),
  shell: legacy(shell), ruby: legacy(ruby), lua: legacy(lua), dockerfile: legacy(dockerFile),
  toml: legacy(toml), perl: legacy(perl), r: legacy(r), powershell: legacy(powerShell),
  protobuf: legacy(protobuf), nginx: legacy(nginx), diff: legacy(diff),
  properties: legacy(properties), cmake: legacy(cmake), haskell: legacy(haskell),
  clojure: legacy(clojure), erlang: legacy(erlang), groovy: legacy(groovy),
  julia: legacy(julia), ocaml: legacy(oCaml), fsharp: legacy(fSharp), sass: legacy(sass),
  crystal: legacy(crystal),
};

function palette(dark) {
  return dark
    ? { bg: "#17191c", fg: "#d8dce1", gutter: "#6b727c", gutterBg: "#17191c", active: "#1f2327",
        sel: "#2b3a5c", kw: "#c792ea", str: "#9ece6a", num: "#ff9e64", com: "#6b7480", fn: "#7aa2f7",
        type: "#2ac3de", prop: "#a9b1d6", op: "#89ddff", tag: "#f7768e", marker: "#2c3035", match: "#3b4261" }
    : { bg: "#fbfbfa", fg: "#1b1e23", gutter: "#9aa0a8", gutterBg: "#fbfbfa", active: "#f1f2f0",
        sel: "#d6e0fb", kw: "#8a3fb8", str: "#2d7d46", num: "#b3541e", com: "#8a9099", fn: "#2b54d9",
        type: "#0b7a8a", prop: "#3d4450", op: "#6b717b", tag: "#c2413b", marker: "#e3e5e1", match: "#e4e9fb" };
}

function themeExtensions(dark) {
  const c = palette(dark);
  const base = EditorView.theme({
    "&": { color: c.fg, backgroundColor: c.bg, height: "100%", fontSize: "var(--mv-code-size, 13px)" },
    ".cm-scroller": { fontFamily: "'SF Mono', ui-monospace, Menlo, monospace", lineHeight: "1.55" },
    ".cm-content": { caretColor: c.fg, padding: "8px 0" },
    ".cm-gutters": { backgroundColor: c.gutterBg, color: c.gutter, border: "none" },
    ".cm-activeLine, .cm-activeLineGutter": { backgroundColor: c.active },
    "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection": { backgroundColor: c.sel + " !important" },
    ".cm-selectionMatch, .cm-searchMatch": { backgroundColor: c.match },
    ".cm-foldGutter .cm-gutterElement": { cursor: "pointer", color: c.gutter },
    ".cm-foldPlaceholder": { backgroundColor: c.active, border: "none", color: c.gutter },
    ".cm-panels": { backgroundColor: c.active, color: c.fg },
    ".mv-flash": { backgroundColor: dark ? "#3a3218" : "#fbefd2" },
  }, { dark });
  const style = HighlightStyle.define([
    { tag: [t.keyword, t.controlKeyword, t.moduleKeyword, t.operatorKeyword, t.definitionKeyword], color: c.kw },
    { tag: [t.string, t.special(t.string), t.regexp], color: c.str },
    { tag: [t.number, t.bool, t.null, t.atom], color: c.num },
    { tag: [t.comment, t.lineComment, t.blockComment, t.docComment], color: c.com, fontStyle: "italic" },
    { tag: [t.function(t.variableName), t.function(t.propertyName)], color: c.fn },
    { tag: [t.typeName, t.className, t.namespace, t.definition(t.typeName)], color: c.type },
    { tag: [t.propertyName, t.attributeName], color: c.prop },
    { tag: [t.operator, t.punctuation, t.bracket], color: c.op },
    { tag: [t.tagName, t.heading], color: c.tag, fontWeight: "600" },
    { tag: t.meta, color: c.com },
  ]);
  return [base, syntaxHighlighting(style), indentationMarkers({
    colors: { light: c.marker, dark: c.marker, activeLight: c.gutter, activeDark: c.gutter } })];
}

/** Create a read-only viewer inside `parent`. Returns a small controller. */
function create(parent, { doc = "", language = "", dark = false } = {}) {
  let currentLanguage = language;
  let isDark = dark;
  const theme = new Compartment();
  const layoutListeners = [];
  const notifyLayout = () => layoutListeners.forEach((fn) => fn());
  const build = () => [
    lineNumbers(), highlightActiveLineGutter(), highlightSpecialChars(), drawSelection(),
    highlightActiveLine(), codeFolding(), foldGutter(), bracketMatching(),
    highlightSelectionMatches(), search({ top: true }), indentUnit.of("    "),
    EditorState.readOnly.of(true), EditorView.editable.of(false),
    EditorView.contentAttributes.of({ tabindex: "0" }),
    keymap.of([...defaultKeymap, ...searchKeymap, ...foldKeymap]),
    languages[currentLanguage] ? languages[currentLanguage]() : [],
    theme.of(themeExtensions(isDark)),
    EditorView.updateListener.of((u) => { if (u.geometryChanged || u.viewportChanged || u.docChanged) notifyLayout(); }),
  ];
  const view = new EditorView({ parent, state: EditorState.create({ doc, extensions: build() }) });
  view.scrollDOM.addEventListener("scroll", notifyLayout, { passive: true });
  return {
    view,
    /** Replace the document (and optionally its language); resets scroll and folds. */
    setDoc(text, nextLanguage) {
      if (nextLanguage !== undefined) currentLanguage = nextLanguage;
      view.setState(EditorState.create({ doc: text, extensions: build() }));
    },
    setTheme(dark) {
      isDark = dark;
      view.dispatch({ effects: theme.reconfigure(themeExtensions(isDark)) });
    },
    /** Select 1-based `line`…`endLine` and scroll it to the centre. */
    gotoLine(line, endLine) {
      const total = view.state.doc.lines;
      const clamp = (n) => Math.min(Math.max(1, n), total);
      const from = view.state.doc.line(clamp(line));
      const to = view.state.doc.line(clamp(Math.max(line, endLine || line)));
      view.dispatch({ selection: { anchor: from.from, head: to.to },
                      effects: EditorView.scrollIntoView(from.from, { y: "center" }) });
    },
    openSearch() { openSearchPanel(view); },
    /** Vertical geometry for margin notes: pixel offsets inside the scrolled content. */
    geometry() {
      const doc = view.state.doc;
      const clamp = (n) => Math.min(Math.max(1, n), doc.lines);
      const pad = view.documentPadding.top;
      return {
        scrollTop: view.scrollDOM.scrollTop,
        height: view.contentHeight,
        lineTop: (n) => view.lineBlockAt(doc.line(clamp(n)).from).top + pad,
        lineBottom: (n) => view.lineBlockAt(doc.line(clamp(n)).from).bottom + pad,
      };
    },
    /** Re-measure after the font size changes (zoom). */
    refresh() { view.requestMeasure(); notifyLayout(); },
    /** Visible height of the scroller, for "fit the whole file". */
    viewportHeight() { return view.scrollDOM.clientHeight; },
    lineCount() { return view.state.doc.lines; },
    /** Call `fn` whenever scroll position or line geometry changes. */
    onLayout(fn) { layoutListeners.push(fn); },
    destroy() { view.destroy(); },
  };
}

window.MVCode = { create, languages: Object.keys(languages) };
