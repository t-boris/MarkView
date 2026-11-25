if (!window[/* @__PURE__ */ Symbol.for("markview.editor.early")]) {
  window[/* @__PURE__ */ Symbol.for("markview.editor.early")] = true;
  (function(root) {
    "use strict";
    function parse(hex2) {
      const m = /^#?([0-9a-f]{6})$/i.exec(String(hex2 || "").trim());
      if (!m) return null;
      const n = parseInt(m[1], 16);
      return [n >> 16 & 255, n >> 8 & 255, n & 255];
    }
    function hex(rgb) {
      return "#" + rgb.map(function(c) {
        return ("0" + Math.max(0, Math.min(255, Math.round(c))).toString(16)).slice(-2);
      }).join("");
    }
    function luminance(h) {
      const c = parse(h).map(function(v) {
        v /= 255;
        return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
      });
      return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
    }
    function contrast(a, b) {
      const x = luminance(a), y = luminance(b);
      return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
    }
    function mix(a, b, t) {
      const p = parse(a), q = parse(b);
      return hex(p.map(function(v, i) {
        return v + (q[i] - v) * t;
      }));
    }
    function rgba(h, alpha) {
      const c = parse(h);
      return "rgba(" + c[0] + ", " + c[1] + ", " + c[2] + ", " + alpha + ")";
    }
    function readableText(h) {
      return contrast(h, "#000000") >= contrast(h, "#ffffff") ? "#000000" : "#ffffff";
    }
    function adjusted(h, target, backgrounds) {
      function ok(c) {
        return backgrounds.every(function(b) {
          return contrast(c, b) >= target;
        });
      }
      if (ok(h)) return h;
      const average = backgrounds.reduce(function(s, b) {
        return s + luminance(b);
      }, 0) / backgrounds.length;
      const end = average < 0.4 ? "#ffffff" : "#000000";
      let fraction = 0;
      while (fraction < 1) {
        fraction = Math.min(fraction + 0.02, 1);
        const candidate = mix(h, end, fraction);
        if (ok(candidate)) return candidate;
      }
      return end;
    }
    const known = {};
    const FALLBACK = "classic-dark";
    function define(definition) {
      if (definition && typeof definition.id === "string" && definition.base && definition.t) known[definition.id] = definition;
    }
    function lookup(id) {
      return known[id] || known[FALLBACK] || null;
    }
    function derive(theme, accentInput) {
      const base = theme.base, t = theme.t, dark = theme.mode === "dark";
      const bg = base.bg.toLowerCase(), panel = base.panel.toLowerCase(), text = base.text.toLowerCase();
      const accent = (accentInput || base.accent).toLowerCase();
      const readable = adjusted(accent, 4.5, [bg, panel]);
      const fill = accent;
      const onFill = readableText(fill);
      const v = {};
      v["--bg-primary"] = bg;
      v["--bg-secondary"] = panel;
      v["--bg-tertiary"] = t.tertiary;
      v["--text-primary"] = text;
      v["--text-secondary"] = t.textSecondary;
      v["--text-tertiary"] = t.textTertiary;
      v["--border-color"] = t.border;
      v["--border-color-light"] = t.borderLight;
      v["--accent-primary"] = readable;
      v["--accent-info"] = readable;
      v["--accent-color"] = readable;
      v["--accent"] = accent;
      v["--accent-fill"] = fill;
      v["--on-accent"] = onFill;
      v["--on-danger"] = readableText(t.danger);
      v["--accent-secondary"] = t.secondary;
      v["--accent-tertiary"] = t.danger;
      v["--accent-warning"] = t.warning;
      v["--accent-success"] = t.success;
      v["--accent-danger"] = t.danger;
      v["--code-bg"] = t.codeBg || t.tertiary;
      v["--code-text"] = text;
      v["--code-border"] = t.border;
      v["--selection-bg"] = rgba(accent, dark ? 0.34 : 0.22);
      v["--selection-color"] = readable;
      v["--shadow-sm"] = dark ? "0 1px 2px rgba(0, 0, 0, 0.3)" : "0 1px 2px rgba(0, 0, 0, 0.07)";
      v["--shadow-md"] = dark ? "0 2px 4px rgba(0, 0, 0, 0.4)" : "0 2px 4px rgba(0, 0, 0, 0.1)";
      v["--shadow-lg"] = dark ? "0 4px 12px rgba(0, 0, 0, 0.5)" : "0 4px 12px rgba(0, 0, 0, 0.12)";
      v["--toolbar-text"] = t.textSecondary;
      v["--toolbar-text-hover"] = text;
      v["--toolbar-hover-bg"] = t.hover;
      v["--toolbar-sep"] = t.border;
      v["--toolbar-active-bg"] = fill;
      v["--toolbar-active-text"] = onFill;
      v["--mode-label"] = t.textTertiary;
      v["--float-bg"] = t.tertiary;
      v["--float-border"] = t.border;
      v["--float-text"] = text;
      v["--float-hover"] = t.hover;
      v["--float-sep"] = t.border;
      v["--scroll-thumb"] = t.border;
      v["--slider-track"] = t.border;
      v["--pre-bg"] = t.preBg;
      v["--pre-border"] = t.preBorder;
      v["--pre-text"] = t.preText;
      v["--h2-color"] = t.h2;
      v["--h3-color"] = t.h3;
      v["--link-underline"] = rgba(accent, 0.3);
      v["--dim-opacity"] = "1";
      v["--code-shadow"] = "none";
      v["--line-numbers"] = t.textTertiary;
      const s = theme.syn;
      v["--syn-comment"] = s.comment;
      v["--syn-punct"] = s.punct;
      v["--syn-property"] = s.property;
      v["--syn-number"] = s.number;
      v["--syn-string"] = s.string;
      v["--syn-operator"] = s.operator;
      v["--syn-func"] = s.func;
      v["--syn-keyword"] = s.keyword;
      v["--syn-regex"] = s.regex;
      const u = theme.struct;
      v["--struct-key"] = u.key;
      v["--struct-string"] = u.string;
      v["--struct-number"] = u.number;
      v["--struct-boolean"] = u.boolean;
      v["--struct-null"] = u.null;
      v["--struct-bracket"] = u.bracket;
      v["--struct-tag"] = u.tag;
      v["--struct-attr-name"] = u.attrName;
      v["--struct-attr-value"] = u.attrValue;
      v["--struct-comment"] = u.comment;
      v["--struct-count"] = u.count;
      v["--struct-hover"] = dark ? "rgba(255, 255, 255, 0.04)" : "rgba(0, 0, 0, 0.04)";
      v["--ok-text"] = t.success;
      v["--warn-text"] = t.warning;
      v["--bad-text"] = t.danger;
      v["--rm-active-bg"] = mix(bg, accent, dark ? 0.3 : 0.22);
      v["--rm-primary-bg"] = fill;
      v["--rm-primary-hover-bg"] = mix(fill, text, 0.18);
      v["--on-rm-primary"] = onFill;
      v["--rm-danger-bg"] = t.danger;
      v["--on-rm-danger"] = readableText(t.danger);
      v["--cv-edge-color"] = t.textTertiary;
      v["--cv-node-bg"] = rgba(panel, 0.92);
      v["--cv-node-border"] = t.border;
      v["--cv-group-label"] = t.textSecondary;
      v["--cv-grid-dot"] = rgba(text, dark ? 0.055 : 0.07);
      v["--dc-bg"] = bg;
      v["--dc-fg"] = text;
      v["--dc-dim"] = t.textSecondary;
      v["--dc-card"] = panel;
      v["--dc-border"] = t.border;
      v["--dc-accent"] = readable;
      v["--dc-user"] = mix(bg, accent, dark ? 0.22 : 0.14);
      v["--dc-code"] = t.codeBg || t.tertiary;
      v["--dc-error"] = t.danger;
      v["--chart-text"] = text;
      v["--chart-grid"] = t.border;
      v["--arch-bg"] = bg;
      v["--arch-node"] = panel;
      v["--arch-box"] = readable;
      v["--arch-box-line"] = t.border;
      v["--arch-line"] = t.border;
      v["--arch-text"] = text;
      v["--arch-mute"] = t.textSecondary;
      v["--arch-accent"] = readable;
      v["--arch-ok"] = t.success;
      v["--arch-warn"] = t.warning;
      v["--arch-bad"] = t.danger;
      v["--arch-info"] = t.secondary;
      v["--cm-bg"] = bg;
      v["--cm-fg"] = text;
      v["--cm-gutter"] = t.textTertiary;
      v["--cm-active"] = panel;
      v["--cm-sel"] = mix(bg, accent, dark ? 0.24 : 0.18);
      v["--cm-kw"] = s.keyword;
      v["--cm-str"] = s.string;
      v["--cm-num"] = s.number;
      v["--cm-com"] = s.comment;
      v["--cm-fn"] = s.func;
      v["--cm-type"] = t.secondary;
      v["--cm-prop"] = s.property;
      v["--cm-op"] = s.operator;
      v["--cm-tag"] = s.property;
      v["--cm-marker"] = t.borderLight;
      v["--cm-match"] = mix(bg, accent, 0.2);
      v["--cm-flash"] = dark ? mix(bg, "#ffd54a", 0.18) : mix(bg, "#ffd54a", 0.35);
      return v;
    }
    function varsFor(id, accentInput) {
      const theme = lookup(id);
      if (!theme) return {};
      const accent = parse(accentInput) ? String(accentInput).toLowerCase() : "";
      const v = derive(theme, accent);
      if (theme.vars) {
        Object.assign(v, theme.vars);
        if (!accent) Object.assign(v, theme.ownAccentVars);
        else {
          v["--link-underline"] = rgba(accent, 0.3);
        }
      }
      const raw = accent || theme.base.accent;
      v["--accent-a15"] = rgba(raw, 0.15);
      v["--accent-a28"] = rgba(raw, 0.28);
      v["--accent-a70"] = rgba(raw, 0.7);
      return v;
    }
    function chartPalette(id, accentInput) {
      const theme = lookup(id);
      if (!theme) return [];
      if (theme.chart) return theme.chart.slice();
      const v = varsFor(id, accentInput), s = theme.syn;
      return [v["--accent-primary"], theme.t.secondary, theme.t.warning, s.func, s.keyword, s.string, theme.t.danger, s.number];
    }
    function terminalTheme(id, accentInput) {
      const theme = lookup(id);
      if (!theme) return {};
      const chosen = parse(accentInput);
      const accent = chosen ? String(accentInput).toLowerCase() : theme.base.accent.toLowerCase();
      const dark = theme.mode === "dark";
      const result = Object.assign({
        background: theme.base.bg.toLowerCase(),
        foreground: theme.base.text.toLowerCase(),
        cursor: adjusted(accent, 3, [theme.base.bg.toLowerCase()]),
        selectionBackground: mix(theme.base.bg, accent, dark ? 0.38 : 0.24)
      }, theme.term);
      if (chosen && theme.term.selectionBackground) result.selectionBackground = mix(theme.base.bg, accentInput, 0.38);
      return result;
    }
    function mermaidConfig(id, accentInput) {
      const theme = lookup(id);
      if (!theme) return {};
      if (theme.mermaid === "builtin") return { theme: theme.mode === "dark" ? "dark" : "default" };
      const v = varsFor(id, accentInput);
      return { theme: "base", themeVariables: {
        darkMode: theme.mode === "dark",
        background: v["--bg-primary"],
        fontFamily: "inherit",
        primaryColor: v["--bg-tertiary"],
        primaryTextColor: v["--text-primary"],
        primaryBorderColor: v["--accent-primary"],
        secondaryColor: v["--bg-secondary"],
        tertiaryColor: v["--bg-secondary"],
        lineColor: v["--text-secondary"],
        textColor: v["--text-primary"],
        mainBkg: v["--bg-tertiary"],
        nodeBorder: v["--accent-primary"],
        clusterBkg: v["--bg-secondary"],
        clusterBorder: v["--border-color"],
        titleColor: v["--text-primary"],
        edgeLabelBackground: v["--bg-primary"],
        noteBkgColor: v["--bg-tertiary"],
        noteTextColor: v["--text-primary"]
      } };
    }
    const state2 = { id: FALLBACK, accent: "" };
    function signature() {
      return state2.id + "|" + state2.accent;
    }
    function apply(id, accentInput, definition, doc) {
      define(definition);
      const theme = lookup(id);
      if (!theme) return current();
      id = theme.id;
      doc = doc || root.document;
      const accent = parse(accentInput) ? String(accentInput).toUpperCase() : "";
      const element = doc.documentElement;
      const vars = varsFor(id, accent);
      Object.keys(vars).forEach(function(name) {
        element.style.setProperty(name, vars[name]);
      });
      element.setAttribute("data-preset", id);
      element.setAttribute("data-theme", theme.mode);
      if (accent) element.setAttribute("data-accent", accent);
      else element.removeAttribute("data-accent");
      if (doc === root.document) {
        state2.id = id;
        state2.accent = accent;
        try {
          root.dispatchEvent(new root.CustomEvent("markview-theme", { detail: current() }));
        } catch (e) {
        }
      }
      return current();
    }
    function applyFromDocument() {
      const element = root.document.documentElement;
      let definition = null;
      try {
        definition = JSON.parse(element.getAttribute("data-theme-tokens") || "null");
      } catch (e) {
      }
      return apply(element.getAttribute("data-preset") || FALLBACK, element.getAttribute("data-accent") || "", definition);
    }
    function current() {
      const theme = known[state2.id];
      if (!theme) return { id: state2.id, mode: "dark", accent: "", override: "", isDark: true };
      return {
        id: state2.id,
        mode: theme.mode,
        accent: state2.accent || theme.base.accent.toUpperCase(),
        override: state2.accent,
        isDark: theme.mode === "dark"
      };
    }
    function token(name) {
      const applied = root.document && root.document.documentElement.style.getPropertyValue(name).trim();
      return applied || varsFor(state2.id, state2.accent)[name];
    }
    const api = {
      ids: function() {
        return Object.keys(known);
      },
      themes: known,
      define,
      apply,
      applyFromDocument,
      current,
      token,
      varsFor,
      terminalTheme,
      mermaidConfig,
      chartPalette,
      mermaid: function() {
        return mermaidConfig(state2.id, state2.accent);
      },
      signature,
      color: { parse, hex, luminance, contrast, mix, rgba, adjusted, readableText }
    };
    root.MarkViewThemes = api;
    if (typeof module !== "undefined" && module.exports) module.exports = api;
    if (root.document && root.document.documentElement) {
      try {
        applyFromDocument();
      } catch (e) {
      }
    }
  })(typeof window !== "undefined" ? window : globalThis);
  ;
  (function(global) {
    "use strict";
    var HTML_ESCAPES = {
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#39;"
    };
    function escapeHtml(value) {
      if (value === null || value === void 0) return "";
      return String(value).replace(/[&<>"']/g, function(ch) {
        return HTML_ESCAPES[ch] || ch;
      });
    }
    function escapeAttr(value) {
      return escapeHtml(value).replace(/`/g, "&#96;");
    }
    function debounce(fn, waitMs) {
      var timer = null;
      var delay = typeof waitMs === "number" && waitMs >= 0 ? waitMs : 150;
      return function() {
        var ctx = this;
        var args = arguments;
        if (timer !== null) clearTimeout(timer);
        timer = setTimeout(function() {
          timer = null;
          fn.apply(ctx, args);
        }, delay);
      };
    }
    function h(tag, attrs, children) {
      var el = document.createElement(tag);
      if (attrs && typeof attrs === "object") {
        Object.keys(attrs).forEach(function(key) {
          var val = attrs[key];
          if (val === null || val === void 0 || val === false) return;
          if (key === "className") {
            el.className = String(val);
          } else if (key === "textContent") {
            el.textContent = String(val);
          } else if (key === "style" && typeof val === "object") {
            Object.keys(val).forEach(function(prop) {
              el.style[prop] = val[prop];
            });
          } else if (key.indexOf("on") === 0 && typeof val === "function") {
            el.addEventListener(key.slice(2).toLowerCase(), val);
          } else {
            el.setAttribute(key, val === true ? "" : String(val));
          }
        });
      }
      if (Array.isArray(children)) {
        children.forEach(function(child) {
          if (child === null || child === void 0) return;
          el.appendChild(typeof child === "string" ? document.createTextNode(child) : child);
        });
      } else if (typeof children === "string") {
        el.textContent = children;
      } else if (children && children.nodeType) {
        el.appendChild(children);
      }
      return el;
    }
    function attachPanZoom(container, target, options) {
      if (!container || !target) return { reset: function() {
      } };
      var opts = options || {};
      var minScale = opts.minScale || 0.2;
      var maxScale = opts.maxScale || 5;
      var state2 = { x: 0, y: 0, scale: 1, dragging: false, startX: 0, startY: 0 };
      function apply() {
        target.style.transform = "translate(" + state2.x + "px, " + state2.y + "px) scale(" + state2.scale + ")";
      }
      container.addEventListener("wheel", function(e) {
        e.preventDefault();
        var factor = e.deltaY < 0 ? 1.1 : 0.9;
        state2.scale = Math.min(maxScale, Math.max(minScale, state2.scale * factor));
        apply();
      }, { passive: false });
      container.addEventListener("mousedown", function(e) {
        if (e.button !== 0) return;
        state2.dragging = true;
        state2.startX = e.clientX - state2.x;
        state2.startY = e.clientY - state2.y;
      });
      global.addEventListener("mousemove", function(e) {
        if (!state2.dragging) return;
        state2.x = e.clientX - state2.startX;
        state2.y = e.clientY - state2.startY;
        apply();
      });
      global.addEventListener("mouseup", function() {
        state2.dragging = false;
      });
      return {
        reset: function() {
          state2.x = 0;
          state2.y = 0;
          state2.scale = 1;
          apply();
        },
        getState: function() {
          return { x: state2.x, y: state2.y, scale: state2.scale };
        }
      };
    }
    var BRIDGE_KINDS = { string: 1, int: 1, number: 1, boolean: 1, object: 1, array: 1, any: 1 };
    var UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    var compiledContract = null;
    var compiledFrom = null;
    var warnedNoContract = false;
    function compileSpec(raw, definitions, depth) {
      if (depth > 8) throw new Error("definitions nest too deep");
      var options = {};
      var typeName;
      var optional = false;
      if (typeof raw === "string") {
        typeName = raw;
      } else if (raw && typeof raw === "object" && typeof raw.type === "string") {
        typeName = raw.type;
        options = raw;
        optional = options.optional === true;
      } else {
        throw new Error("not a type");
      }
      if (typeName.charAt(typeName.length - 1) === "?") {
        optional = true;
        typeName = typeName.slice(0, -1);
      }
      if (!BRIDGE_KINDS[typeName]) {
        if (!definitions || !definitions[typeName]) throw new Error("unknown type " + typeName);
        var resolved = compileSpec(definitions[typeName], definitions, depth + 1);
        resolved.optional = optional || resolved.optional;
        return resolved;
      }
      var spec = {
        kind: typeName,
        optional,
        nonEmpty: options.nonEmpty === true,
        min: typeof options.min === "number" ? options.min : null,
        max: typeof options.max === "number" ? options.max : null,
        maxItems: typeof options.maxItems === "number" ? options.maxItems : null,
        allowed: null,
        isUUID: options.format === "uuid",
        fields: null,
        items: null
      };
      if (Array.isArray(options.enum)) {
        spec.allowed = /* @__PURE__ */ Object.create(null);
        options.enum.forEach(function(value) {
          spec.allowed[value] = true;
        });
      }
      if (options.fields) spec.fields = compileFields(options.fields, definitions);
      if (options.items !== void 0) spec.items = compileSpec(options.items, definitions, depth + 1);
      return spec;
    }
    function compileFields(fields, definitions) {
      var compiled = {};
      Object.keys(fields).forEach(function(name) {
        compiled[name] = compileSpec(fields[name], definitions, 0);
      });
      return compiled;
    }
    function compileContract(contract) {
      var channels = /* @__PURE__ */ Object.create(null);
      var definitions = contract.definitions || {};
      Object.keys(contract.channels).forEach(function(channelName) {
        var messages = /* @__PURE__ */ Object.create(null);
        var declared = contract.channels[channelName].messages;
        Object.keys(declared).forEach(function(type) {
          var entry = declared[type];
          var payload = entry.fields ? { kind: "object", optional: false, fields: compileFields(entry.fields, definitions) } : { kind: "array", optional: false, items: compileSpec(entry.items, definitions, 0) };
          messages[type] = { payload, mainFrameOnly: entry.mainFrameOnly === true };
        });
        channels[channelName] = messages;
      });
      return channels;
    }
    function contractChannels() {
      var contract = global.mvBridgeContract;
      if (!contract || typeof contract !== "object" || !contract.channels) return null;
      if (compiledFrom !== contract) {
        compiledContract = compileContract(contract);
        compiledFrom = contract;
      }
      return compiledContract;
    }
    function bridgeProblem(spec, value, path) {
      if (value === void 0 || value === null) return spec.optional ? "" : path + " is missing";
      switch (spec.kind) {
        case "any":
          return "";
        case "string":
          if (typeof value !== "string") return path + " is not a string";
          if (spec.nonEmpty && value.length === 0) return path + " is empty";
          if (spec.allowed && spec.allowed[value] !== true) return path + " is not a declared value";
          if (spec.isUUID && !UUID_PATTERN.test(value)) return path + " is not a UUID";
          return "";
        case "int":
        case "number":
          if (typeof value !== "number") return path + " is not a " + (spec.kind === "int" ? "whole number" : "number");
          if (!isFinite(value)) return path + " is not finite";
          if (spec.kind === "int" && (Math.floor(value) !== value || Math.abs(value) > 9007199254740992)) return path + " is not a whole number";
          if (spec.min !== null && value < spec.min) return path + " is below its minimum";
          if (spec.max !== null && value > spec.max) return path + " is above its maximum";
          return "";
        case "boolean":
          return typeof value === "boolean" ? "" : path + " is not a boolean";
        case "object":
          if (typeof value !== "object" || Array.isArray(value)) return path + " is not an object";
          if (spec.fields) {
            var names = Object.keys(spec.fields);
            for (var i = 0; i < names.length; i++) {
              var problem = bridgeProblem(spec.fields[names[i]], value[names[i]], path + "." + names[i]);
              if (problem) return problem;
            }
          }
          return "";
        case "array":
          if (!Array.isArray(value)) return path + " is not an array";
          if (spec.maxItems !== null && value.length > spec.maxItems) return path + " has too many items";
          if (spec.items) {
            for (var j = 0; j < value.length; j++) {
              var itemProblem = bridgeProblem(spec.items, value[j], path + "[" + j + "]");
              if (itemProblem) return itemProblem;
            }
          }
          return "";
      }
      return path + " has an unknown type";
    }
    function outboundProblem(channel, type, payload) {
      var channels = contractChannels();
      if (!channels) return "no bridge contract on this page";
      var messages = channels[channel];
      if (!messages) return "channel " + channel + " is not in the contract";
      var message = messages[String(type)];
      if (!message) return channel + "/" + String(type) + " is not in the contract";
      if (payload === void 0 && message.payload.kind === "object") payload = {};
      var problem = bridgeProblem(message.payload, payload, "payload");
      return problem ? channel + "/" + type + ": " + problem : "";
    }
    var mvBridge = {
      // Posts one message to the app. Returns false when the message was refused or the page has no app to send it to.
      send: function(type, payload, channel) {
        var name = channel || "bridge";
        var problem = outboundProblem(name, type, payload);
        if (problem) {
          if (problem === "no bridge contract on this page") {
            if (warnedNoContract) return false;
            warnedNoContract = true;
          }
          if (global.console && global.console.error) global.console.error("[mvBridge] refused: " + problem);
          return false;
        }
        var handler = global.webkit && global.webkit.messageHandlers && global.webkit.messageHandlers[name];
        if (!handler) return false;
        handler.postMessage({
          type,
          payload: payload !== void 0 ? payload : {},
          doc: global.mvDocumentId || ""
        });
        return true;
      }
    };
    var STYLE_PROPERTY_ALLOW = new RegExp("^(?:" + [
      "(?:align|justify|place)-[a-z-]+",
      "alignment-baseline",
      "animation(?:-[a-z-]+)?",
      "aspect-ratio",
      "backdrop-filter",
      "backface-visibility",
      "background(?:-[a-z-]+)?",
      "baseline-shift",
      "border(?:-[a-z-]+)?",
      "bottom",
      "box-[a-z-]+",
      "caption-side",
      "clear",
      "clip-path",
      "clip-rule",
      "color",
      "color-interpolation(?:-filters)?",
      "column-[a-z-]+",
      "columns",
      "counter-[a-z-]+",
      "cursor",
      "cx",
      "cy",
      "direction",
      "display",
      "dominant-baseline",
      "empty-cells",
      "fill(?:-[a-z-]+)?",
      "filter",
      "flex(?:-[a-z-]+)?",
      "float",
      "flood-[a-z-]+",
      "font(?:-[a-z-]+)?",
      "gap",
      "grid(?:-[a-z-]+)?",
      "height",
      "hyphens",
      "image-rendering",
      "inset(?:-[a-z-]+)?",
      "left",
      "letter-spacing",
      "lighting-color",
      "line-[a-z-]+",
      "list-style(?:-[a-z-]+)?",
      "margin(?:-[a-z-]+)?",
      "marker(?:-[a-z-]+)?",
      "mask(?:-[a-z-]+)?",
      "max-[a-z-]+",
      "min-[a-z-]+",
      "mix-blend-mode",
      "object-[a-z-]+",
      "opacity",
      "order",
      "orphans",
      "outline(?:-[a-z-]+)?",
      "overflow(?:-[a-z-]+)?",
      "padding(?:-[a-z-]+)?",
      "paint-order",
      "perspective(?:-[a-z-]+)?",
      "pointer-events",
      "position",
      "quotes",
      "r",
      "right",
      "rotate",
      "row-gap",
      "rx",
      "ry",
      "scale",
      "shape-rendering",
      "stop-[a-z-]+",
      "stroke(?:-[a-z-]+)?",
      "tab-size",
      "table-layout",
      "text-[a-z-]+",
      "top",
      "transform(?:-[a-z-]+)?",
      "transition(?:-[a-z-]+)?",
      "translate",
      "unicode-bidi",
      "user-select",
      "vector-effect",
      "vertical-align",
      "visibility",
      "white-space",
      "widows",
      "width",
      "word-[a-z-]+",
      "writing-mode"
    ].join("|") + ")$");
    var STYLE_VALUE_UNSAFE = /(?:^|[^\w-])(?:-webkit-)?(?:image|image-set|cross-fade|element|paint|canvas|src)\(|expression\s*\(|javascript:|vbscript:|@import|-moz-binding|behavior\s*:/i;
    var STYLE_URL = /url\(\s*(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|([^)"'\s]*))\s*\)/gi;
    var MAX_STYLE_DECLARATIONS = 200;
    var URL_ATTRS = ["src", "href", "xlink:href", "action", "formaction", "poster"];
    var COMMON_FORBID_TAGS = ["script", "iframe", "object", "embed", "form", "base", "meta", "link", "style"];
    var COMMON_FORBID_ATTR = [
      "onerror",
      "onload",
      "onclick",
      "onmouseover",
      "onmouseenter",
      "onmouseleave",
      "onfocus",
      "onblur",
      "onkeydown",
      "onkeyup",
      "onkeypress",
      "onsubmit",
      "onchange",
      "oninput",
      "onmousedown",
      "onmouseup",
      "oncontextmenu",
      "ondblclick",
      "ondrag",
      "ondrop",
      "onpaste",
      "oncopy",
      "oncut",
      "onanimationstart",
      "onanimationend",
      "ontoggle"
    ];
    var SANITIZE_PROFILES = {
      markdown: {
        ADD_TAGS: ["details", "summary", "input", "annotation", "semantics"],
        ADD_ATTR: ["target", "checked", "disabled", "type", "open", "contenteditable", "aria-hidden", "style", "class", "id", "title", "alt", "src", "href", "width", "height", "align", "colspan", "rowspan"],
        ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto|tel|markview-doc|markview-wikilink):|data:image\/(?:png|jpe?g|gif|webp|avif)[;,]|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i,
        FORBID_TAGS: COMMON_FORBID_TAGS
      },
      book: {
        ADD_TAGS: ["details", "summary", "input", "annotation", "semantics", "book-preserve"],
        ADD_ATTR: ["target", "checked", "disabled", "type", "open", "aria-hidden", "style", "class", "id", "title", "alt", "src", "href", "width", "height", "colspan", "rowspan", "start", "data-wikilink", "data-book-passage", "viewBox", "preserveAspectRatio", "d", "x", "y", "x1", "y1", "x2", "y2", "stroke-width", "encoding", "display", "mathvariant"],
        ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto|tel|markview-doc|markview-wikilink):|data:image\/(?:png|jpe?g|gif|webp|avif)[;,]|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i,
        FORBID_TAGS: COMMON_FORBID_TAGS.concat(["video", "audio", "button", "textarea", "select"])
      },
      discussion: {
        ADD_TAGS: ["details", "summary", "canvas", "button", "figure", "figcaption"],
        ADD_ATTR: ["target", "open", "class", "id", "title", "alt", "src", "href", "width", "height", "viewBox", "data-kind", "data-src", "data-expand", "data-save", "data-copy"],
        ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto|tel):|data:image\/(?:png|jpe?g|gif|webp|avif)[;,]|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i,
        FORBID_TAGS: COMMON_FORBID_TAGS
      },
      insight: {
        ADD_TAGS: ["details", "summary", "annotation", "semantics", "canvas"],
        ADD_ATTR: ["class", "id", "style", "data-chart", "data-chart-config", "data-mermaid", "data-katex", "aria-hidden", "target", "colspan", "rowspan", "width", "height", "title", "alt", "src", "href", "open"],
        ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto):|data:image\/(?:png|jpe?g|gif|webp|avif)[;,]|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i,
        FORBID_TAGS: COMMON_FORBID_TAGS
      }
    };
    function urlsAreInline(text) {
      var allowed = true;
      var rest = text.replace(STYLE_URL, function(all, double, single, bare) {
        var target = String(double || single || bare || "").replace(/[\u0000-\u0020]+/g, "");
        if (!(target.charAt(0) === "#" || /^data:image\/(?:png|jpe?g|gif|webp|avif)[;,]/i.test(target))) allowed = false;
        return "";
      });
      return allowed && !/url\(/i.test(rest);
    }
    function isSafeDeclaration(property, value) {
      var name = String(property || "").toLowerCase();
      var text = String(value || "");
      if (!name || !text || text.indexOf("<") >= 0) return false;
      if (name.indexOf("--") === 0) {
        if (/\\|\/\*/.test(text)) return false;
      } else {
        if (!STYLE_PROPERTY_ALLOW.test(name.replace(/^-webkit-/, ""))) return false;
        if (name === "position" && !/^(?:static|relative)$/i.test(text)) return false;
      }
      return !STYLE_VALUE_UNSAFE.test(text) && urlsAreInline(text);
    }
    function sanitizeStyleAttribute(rawStyle) {
      var holder = cssParserDocument().createElement("div");
      holder.style.cssText = String(rawStyle || "");
      return safeDeclarations(holder.style);
    }
    var cssParserDoc = null;
    var cssCleanStyle = null;
    function cssParserDocument() {
      if (!cssParserDoc) {
        cssParserDoc = global.document.implementation.createHTMLDocument("");
        cssCleanStyle = cssParserDoc.createElement("div").style;
      }
      return cssParserDoc;
    }
    function splitScopedSelectors(text) {
      var parts = [], depth = 0, quote = "", start = 0;
      for (var i = 0; i < text.length; i++) {
        var ch = text.charAt(i);
        if (quote) {
          if (ch === "\\") i++;
          else if (ch === quote) quote = "";
        } else if (ch === "\\") {
          i++;
        } else if (ch === '"' || ch === "'") {
          quote = ch;
        } else if (ch === "(" || ch === "[") {
          depth++;
        } else if (ch === ")" || ch === "]") {
          if (--depth < 0) return null;
        } else if (depth === 0 && ch === ",") {
          parts.push(text.slice(start, i));
          start = i + 1;
        } else if (depth === 0 && (ch === "+" || ch === "~")) {
          return null;
        }
      }
      if (depth !== 0 || quote) return null;
      parts.push(text.slice(start));
      return parts;
    }
    function safeDeclarations(source) {
      if (source.length > MAX_STYLE_DECLARATIONS) return "";
      cssParserDocument();
      var target = cssCleanStyle;
      target.cssText = "";
      for (var i = 0; i < source.length; i++) {
        var property = source[i];
        var value = source.getPropertyValue(property);
        if (isSafeDeclaration(property, value)) target.setProperty(property, value, source.getPropertyPriority(property));
      }
      return target.cssText;
    }
    function sanitizeScopedStylesheet(cssText, scopeId) {
      var doc = cssParserDocument();
      var style = doc.createElement("style");
      style.textContent = String(cssText || "");
      doc.head.appendChild(style);
      var scope = new RegExp("^#" + global.CSS.escape(scopeId) + "(?![\\w-])");
      var rules = [];
      Array.prototype.forEach.call(style.sheet ? style.sheet.cssRules : [], function(rule) {
        if (rule.type !== 1) return;
        var selectors = splitScopedSelectors(rule.selectorText);
        if (!selectors || !selectors.every(function(selector) {
          return scope.test(selector.trim());
        })) return;
        var body = safeDeclarations(rule.style);
        var text = rule.selectorText + "{" + body + "}";
        if (body && text.indexOf("<") < 0) rules.push(text);
      });
      style.remove();
      return rules.join("\n");
    }
    function ensureDOMPurifyURIHook(purify) {
      if (!purify || typeof purify.addHook !== "function" || purify.__markviewURIHookInstalled) return;
      purify.__markviewURIHookInstalled = true;
      purify.addHook("afterSanitizeAttributes", function(node) {
        if (!node || !node.hasAttribute) return;
        URL_ATTRS.forEach(function(attr) {
          if (!node.hasAttribute(attr)) return;
          var val = node.getAttribute(attr).replace(/[\u0000-\u0020]+/g, "");
          if (/^file:/i.test(val) || /^data:/i.test(val) && !/^data:image\/(?:png|jpe?g|gif|webp|avif)[;,]/i.test(val)) {
            node.removeAttribute(attr);
          }
        });
        if (node.hasAttribute("style")) {
          var cleanStyle = sanitizeStyleAttribute(node.getAttribute("style"));
          if (cleanStyle) {
            node.setAttribute("style", cleanStyle);
          } else {
            node.removeAttribute("style");
          }
        }
      });
    }
    function sanitizeHtml(rawHTML, profile) {
      var purify = global.DOMPurify;
      if (purify && typeof purify.sanitize === "function") {
        ensureDOMPurifyURIHook(purify);
        var cfg = SANITIZE_PROFILES[profile] || SANITIZE_PROFILES.markdown;
        return purify.sanitize(String(rawHTML || ""), {
          USE_PROFILES: { html: true, svg: true, mathMl: true },
          ADD_TAGS: cfg.ADD_TAGS,
          ADD_ATTR: cfg.ADD_ATTR,
          ALLOW_DATA_ATTR: true,
          DATA_URI_TAGS: [],
          ALLOW_UNKNOWN_PROTOCOLS: false,
          ALLOWED_URI_REGEXP: cfg.ALLOWED_URI_REGEXP,
          FORBID_TAGS: cfg.FORBID_TAGS,
          FORBID_ATTR: COMMON_FORBID_ATTR
        });
      }
      return '<pre class="sanitization-error">' + escapeHtml(rawHTML) + "</pre>";
    }
    function sanitizeMermaidSvg(rawSVG) {
      var purify = global.DOMPurify;
      if (purify && typeof purify.sanitize === "function") {
        ensureDOMPurifyURIHook(purify);
        var body = purify.sanitize(String(rawSVG || ""), {
          USE_PROFILES: { svg: true, svgFilters: true, html: true },
          ADD_TAGS: ["foreignObject"],
          // Mermaid writes its node labels as HTML inside <foreignObject>; DOMPurify 3 keeps only <annotation-xml> as an
          // HTML integration point by default and would empty every label.
          HTML_INTEGRATION_POINTS: { "foreignobject": true, "annotation-xml": true },
          ALLOW_DATA_ATTR: false,
          ALLOW_UNKNOWN_PROTOCOLS: false,
          FORBID_TAGS: COMMON_FORBID_TAGS.filter(function(tag) {
            return tag !== "style";
          }),
          FORBID_ATTR: ["onerror", "onload", "onclick", "onmouseover", "onmouseenter", "onmouseleave", "onfocus", "onblur"],
          RETURN_DOM: true
        });
        var svg = body.querySelector("svg");
        var scopeId = svg ? svg.getAttribute("id") : "";
        Array.prototype.forEach.call(body.querySelectorAll("style"), function(style) {
          var css = scopeId ? sanitizeScopedStylesheet(style.textContent, scopeId) : "";
          if (css) style.textContent = css;
          else style.remove();
        });
        return body.innerHTML;
      }
      return '<pre class="sanitization-error">Sanitizer unavailable.</pre>';
    }
    global.mvKit = {
      escapeHtml,
      escapeAttr,
      debounce,
      h,
      attachPanZoom,
      sanitizeHtml,
      sanitizeMermaidSvg
    };
    global.mvEscapeHtml = escapeHtml;
    global.mvBridge = mvBridge;
  })(typeof window !== "undefined" ? window : globalThis);
}
/*! MARKVIEW_EDITOR_EARLY_END */
(function installEarlyErrorCapture() {
  function postEarlyDiag(payload) {
    try {
      window.mvBridge.send("jsError", payload, "bridge");
    } catch (_) {
    }
  }
  window.addEventListener("error", function(event) {
    postEarlyDiag({
      where: "early-window.error",
      message: String(event.message || event.error || "unknown"),
      source: String(event.filename || "inline"),
      lineno: event.lineno || 0,
      colno: event.colno || 0,
      stack: event.error && event.error.stack ? String(event.error.stack) : ""
    });
  });
  window.addEventListener("unhandledrejection", function(event) {
    const reason = event.reason;
    postEarlyDiag({
      where: "early-unhandledrejection",
      message: reason && reason.message ? String(reason.message) : String(reason),
      source: "promise",
      lineno: 0,
      colno: 0,
      stack: reason && reason.stack ? String(reason.stack) : ""
    });
  });
  postEarlyDiag({ where: "init-checkpoint", message: "early-error-capture installed", source: "", lineno: 0, colno: 0, stack: "" });
})();
;
const state = {
  mode: "source",
  // 'source' | 'preview' | 'structured' | 'structured-source' | 'insight'
  theme: document.documentElement.getAttribute("data-theme") || "dark",
  // 'dark' | 'light', the mode of the window theme
  markdown: "",
  headings: [],
  activeHeadingId: null,
  isRendering: false,
  documentBaseURL: null,
  // file:// URL of the current document's directory
  fileType: "markdown",
  // 'markdown' | 'json' | 'xml' | 'yaml' | 'canvas'
  // Recursive Insight v2 — iframe-based session state.
  // See task 5 / tech-spec Decisions 2, 5, 11.
  insightIframe: null,
  // <iframe> DOM node (recreated on each loadInsightSkeleton)
  insightSessionId: null,
  // string | null
  insightCurrentNodeId: null,
  // string | null
  insightSkeleton: null,
  // last skeleton object
  insightSectionLibsNeeded: /* @__PURE__ */ new Set(),
  // Set<string> — lib names in use for current skeleton
  insightLibBytes: /* @__PURE__ */ new Map(),
  // Map<libName, sourceText> — fetch cache
  insightLoadTimer: null,
  // setTimeout handle for 10s iframe-ready timeout
  insightIframeReady: false,
  // true once iframe posts insightIframeReady
  insightPendingChunks: /* @__PURE__ */ new Map()
  // Map<sectionId, [htmlChunk]> — buffered until iframe ready
};
const DOM = {
  container: document.querySelector(".editor-container"),
  toolbar: document.querySelector(".editor-toolbar"),
  editor: document.getElementById("editor-input"),
  editorPane: document.getElementById("editor-pane"),
  previewPane: document.getElementById("preview-pane"),
  rendered: document.getElementById("editor-rendered"),
  statusMode: document.getElementById("status-mode"),
  statusWords: document.getElementById("status-words"),
  statusChars: document.getElementById("status-chars"),
  btnToggleMode: document.getElementById("btn-toggle-mode"),
  tocStatus: document.getElementById("toc-status"),
  // Insight v2 chrome containers
  insightContainer: document.getElementById("insight-container"),
  insightBreadcrumbs: document.getElementById("insight-breadcrumbs"),
  insightIframe: document.getElementById("insight-iframe"),
  insightStatusBar: document.getElementById("insight-status-bar")
};
let md = null;
try {
  md = window.markdownit({
    html: true,
    breaks: true,
    linkify: true,
    typographer: true
  });
  if (window.markdownitFootnote) md.use(window.markdownitFootnote);
  if (window.markdownitTaskLists) md.use(window.markdownitTaskLists, { label: true });
  if (window.markdownitContainer) {
    const containerConfig = {
      info: { emoji: "\u2139\uFE0F", label: "Info" },
      warning: { emoji: "\u26A0\uFE0F", label: "Warning" },
      tip: { emoji: "\u{1F4A1}", label: "Tip" },
      danger: { emoji: "\u{1F534}", label: "Danger" }
    };
    Object.entries(containerConfig).forEach(([name, cfg]) => {
      md.use(window.markdownitContainer, name, {
        render: function(tokens, idx) {
          if (tokens[idx].nesting === 1) {
            return '<div class="admonition ' + name + '">\n<div class="admonition-title">' + cfg.emoji + " " + cfg.label + "</div>\n";
          } else {
            return "</div>\n";
          }
        }
      });
    });
  }
  md.renderer.rules.image = function(tokens, idx, options, env, renderer) {
    const token = tokens[idx];
    const esc = window.mvKit.escapeHtml;
    const src = esc(token.attrGet("src") || "");
    const alt = esc(token.content || "");
    const title = esc(token.attrGet("title") || "");
    return '<img src="' + src + '" alt="' + alt + '" title="' + title + '" style="max-width: 100%; height: auto; border-radius: 6px;">';
  };
} catch (e) {
  console.warn("markdown-it initialization failed:", e);
}
try {
  if (typeof mermaid !== "undefined") {
    mermaid.initialize(Object.assign({ startOnLoad: false, securityLevel: "strict" }, MarkViewThemes.mermaid()));
  }
} catch (e) {
  console.warn("Mermaid initialization failed:", e);
}
;
(function(root) {
  "use strict";
  const SCHEME = "markview-doc";
  const SELF_CONTAINED = /^(?:#|[a-z][a-z0-9+.-]*:)/i;
  function pictureURL(src, baseURL) {
    if (!src || !baseURL) return null;
    const written = String(src).trim();
    if (!written || SELF_CONTAINED.test(written) && !/^file:/i.test(written)) return null;
    let file;
    try {
      file = new URL(written, baseURL);
    } catch (e) {
      return null;
    }
    if (file.protocol !== "file:" || file.host) return null;
    return SCHEME + "://" + file.pathname;
  }
  function pictureSrcset(value, baseURL) {
    if (!value || /data:/i.test(value)) return null;
    let changed = false;
    const candidates = String(value).split(",").map(function(candidate) {
      const parts = candidate.trim().split(/\s+/);
      const resolved = pictureURL(parts[0], baseURL);
      if (!resolved) return candidate.trim();
      changed = true;
      return [resolved].concat(parts.slice(1)).join(" ");
    });
    return changed ? candidates.join(", ") : null;
  }
  function withOriginalPaths(html) {
    const holder = document.createElement("div");
    holder.innerHTML = html;
    [["src", "data-mv-src"], ["srcset", "data-mv-srcset"], ["href", "data-mv-href"]].forEach(function(pair) {
      holder.querySelectorAll("[" + pair[1] + "]").forEach(function(element) {
        element.setAttribute(pair[0], element.getAttribute(pair[1]));
        element.removeAttribute(pair[1]);
      });
    });
    return holder.innerHTML;
  }
  function resolvePictures(container, baseURL) {
    if (!baseURL) return;
    container.querySelectorAll("img[src]").forEach(function(img) {
      const written = img.getAttribute("src");
      const resolved = pictureURL(written, baseURL);
      if (!resolved) return;
      img.setAttribute("data-mv-src", written);
      img.setAttribute("src", resolved);
    });
    container.querySelectorAll("img[srcset], source[srcset]").forEach(function(element) {
      const written = element.getAttribute("srcset");
      const resolved = pictureSrcset(written, baseURL);
      if (!resolved) return;
      element.setAttribute("data-mv-srcset", written);
      element.setAttribute("srcset", resolved);
    });
  }
  const api = { pictureURL, pictureSrcset, withOriginalPaths, resolvePictures };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  root.MarkViewDocumentFiles = api;
})(typeof window !== "undefined" ? window : globalThis);
;
(function() {
  if (!md) return;
  md.inline.ruler.before("link", "wikilink", function(state2, silent) {
    const src = state2.src;
    let pos = state2.pos;
    const embed = src.charCodeAt(pos) === 33;
    if (embed) pos += 1;
    if (src.charCodeAt(pos) !== 91 || src.charCodeAt(pos + 1) !== 91) return false;
    const end = src.indexOf("]]", pos + 2);
    if (end < 0) return false;
    const inner = src.slice(pos + 2, end);
    if (!inner.trim() || inner.indexOf("\n") >= 0 || inner.indexOf("[[") >= 0) return false;
    if (!silent) {
      const bar = inner.indexOf("|");
      const target = (bar >= 0 ? inner.slice(0, bar) : inner).trim();
      const label = bar >= 0 ? inner.slice(bar + 1).trim() : target.replace(/^#/, "").replace(/#/g, " \u203A ");
      const token = state2.push("wikilink", "", 0);
      token.meta = { target, label, embed, raw: src.slice(state2.pos, end + 2) };
    }
    state2.pos = end + 2;
    return true;
  });
  md.renderer.rules.wikilink = function(tokens, idx) {
    const m = tokens[idx].meta;
    return '<a class="wikilink' + (m.embed ? " wikilink-embed" : "") + '" href="#" data-wikilink="' + window.mvKit.escapeAttr(m.target) + '" data-raw="' + window.mvKit.escapeAttr(m.raw) + '">' + (m.embed ? "\u{1F4CE} " : "") + md.utils.escapeHtml(m.label) + "</a>";
  };
  function renderMath(tex, display) {
    if (typeof katex === "undefined") return md.utils.escapeHtml(tex);
    try {
      return katex.renderToString(tex, { displayMode: display, throwOnError: false });
    } catch (e) {
      return md.utils.escapeHtml(tex);
    }
  }
  md.block.ruler.before("fence", "math_block", function(state2, startLine, endLine, silent) {
    const start = state2.bMarks[startLine] + state2.tShift[startLine];
    const max = state2.eMarks[startLine];
    const first = state2.src.slice(start, max);
    if (!first.startsWith("$$")) return false;
    if (silent) return true;
    let content, line = startLine;
    const rest = first.slice(2);
    if (rest.trim().endsWith("$$") && rest.trim().length > 2) {
      content = rest.trim().slice(0, -2);
    } else {
      const lines = [rest];
      let found = false;
      while (++line < endLine) {
        const text = state2.src.slice(state2.bMarks[line] + state2.tShift[line], state2.eMarks[line]);
        const close = text.indexOf("$$");
        if (close >= 0) {
          lines.push(text.slice(0, close));
          found = true;
          break;
        }
        lines.push(text);
      }
      if (!found) return false;
      content = lines.join("\n");
    }
    const token = state2.push("math_block", "div", 0);
    token.block = true;
    token.content = content.trim();
    token.map = [startLine, line + 1];
    state2.line = line + 1;
    return true;
  }, { alt: ["paragraph", "reference", "blockquote", "list"] });
  md.renderer.rules.math_block = function(tokens, idx) {
    const t = tokens[idx];
    const lineAttr = t.attrGet("data-line") ? ' data-line="' + t.attrGet("data-line") + '"' : "";
    return '<div class="math-block" contenteditable="false" data-tex="' + window.mvKit.escapeAttr(t.content) + '"' + lineAttr + ">" + renderMath(t.content, true) + "</div>\n";
  };
  md.inline.ruler.after("escape", "math_inline", function(state2, silent) {
    const src = state2.src, pos = state2.pos;
    if (src.charCodeAt(pos) !== 36 || src.charCodeAt(pos + 1) === 36) return false;
    const next = src.charAt(pos + 1);
    if (!next || /\s/.test(next)) return false;
    let end = pos + 1;
    while ((end = src.indexOf("$", end)) >= 0) {
      if (src.charCodeAt(end - 1) !== 92) break;
      end += 1;
    }
    if (end < 0 || /\s/.test(src.charAt(end - 1)) || /\d/.test(src.charAt(end + 1) || "")) return false;
    if (!silent) {
      const token = state2.push("math_inline", "span", 0);
      token.content = src.slice(pos + 1, end);
    }
    state2.pos = end + 1;
    return true;
  });
  md.renderer.rules.math_inline = function(tokens, idx) {
    const tex = tokens[idx].content;
    return '<span class="math-inline" contenteditable="false" data-tex="' + window.mvKit.escapeAttr(tex) + '">' + renderMath(tex, false) + "</span>";
  };
  function normalize(text) {
    return String(text).replace(/\s+/g, " ").trim().toLowerCase();
  }
  window.scrollToHeadingText = function(name, root) {
    const wanted = normalize(name);
    const headings = Array.from((root || document).querySelectorAll("h1, h2, h3, h4, h5, h6"));
    const hit = headings.find(function(h) {
      return normalize(h.textContent) === wanted;
    }) || headings.find(function(h) {
      return normalize(h.textContent).indexOf(wanted) === 0;
    });
    if (hit) hit.scrollIntoView({ behavior: "smooth", block: "start" });
    return !!hit;
  };
  document.addEventListener("click", function(e) {
    const link = e.target.closest && e.target.closest("a.wikilink");
    if (!link) return;
    e.preventDefault();
    e.stopPropagation();
    const target = link.getAttribute("data-wikilink") || "";
    const hash = target.indexOf("#");
    const note = hash >= 0 ? target.slice(0, hash).trim() : target.trim();
    const heading = hash >= 0 ? target.slice(hash + 1).trim() : "";
    if (!note) {
      window.scrollToHeadingText(heading, link.closest(".md-viewer, #editor-rendered") || document);
      return;
    }
    sendToSwift("linkClicked", { href: "markview-wikilink:" + encodeURIComponent(note) + (heading ? "#" + encodeURIComponent(heading) : "") });
  }, true);
})();
;
function resolveLocalURLs() {
  if (!state.documentBaseURL) return;
  MarkViewDocumentFiles.resolvePictures(DOM.rendered, state.documentBaseURL);
  DOM.rendered.querySelectorAll("a").forEach((a) => {
    const href = a.getAttribute("href");
    if (!href || href.startsWith("#") || href.startsWith("http://") || href.startsWith("https://") || href.startsWith("file://") || href.startsWith("mailto:") || href.startsWith("data:")) return;
    try {
      a.setAttribute("href", new URL(href, state.documentBaseURL).href);
      a.setAttribute("data-mv-href", href);
    } catch (e) {
    }
  });
}
let mermaidRunId = 0;
let mermaidSerial = 0;
const MERMAID_CHUNK_MS = 600;
async function drawMermaidDiagrams(runId) {
  const body = DOM.rendered.querySelector(".markdown-body");
  if (!body) return;
  const pending = Array.from(body.querySelectorAll(".mermaid"));
  const failed = [];
  let next = 0;
  while (next < pending.length) {
    if (runId !== mermaidRunId) return;
    const chunkStart = performance.now();
    const scrollTop = DOM.rendered.scrollTop;
    const selection = window.getSelection();
    const range = selection && selection.rangeCount && body.contains(selection.anchorNode) ? selection.getRangeAt(0).cloneRange() : null;
    body.style.display = "none";
    try {
      while (next < pending.length && performance.now() - chunkStart < MERMAID_CHUNK_MS) {
        const node = pending[next++];
        if (!node.isConnected) continue;
        const id = "mv-mermaid-" + ++mermaidSerial;
        try {
          const drawn = await mermaid.render(id, node.textContent);
          node.innerHTML = window.mvKit.sanitizeMermaidSvg(drawn.svg);
          node.setAttribute("data-processed", "true");
          if (drawn.bindFunctions) drawn.bindFunctions(node);
        } catch (e) {
          const scratch = document.getElementById("d" + id);
          if (scratch) scratch.remove();
          failed.push(node);
        }
      }
    } finally {
      body.style.display = "";
      DOM.rendered.scrollTop = scrollTop;
      if (range) {
        selection.removeAllRanges();
        selection.addRange(range);
      }
    }
    try {
      decorateMermaidDiagrams();
    } catch (e) {
    }
    if (next < pending.length) await new Promise((resolve) => setTimeout(resolve, 0));
  }
  if (failed.length && runId === mermaidRunId) {
    try {
      await mermaid.run({ nodes: failed });
    } catch (e) {
    }
    try {
      decorateMermaidDiagrams();
    } catch (e) {
    }
  }
}
function sanitizeMarkdownHTML(rawHTML) {
  return window.mvKit.sanitizeHtml(rawHTML, "markdown");
}
window.sanitizeMarkdownHTML = sanitizeMarkdownHTML;
function renderMarkdown() {
  if (state.isRendering) return;
  state.isRendering = true;
  try {
    const markdown = DOM.editor.value;
    state.markdown = markdown;
    let frontmatter = null;
    let contentMd = markdown;
    const fmMatch = markdown.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
    if (fmMatch) {
      frontmatter = fmMatch[1];
      contentMd = fmMatch[2];
    }
    let html;
    if (md) {
      const offset = fmMatch ? markdown.slice(0, markdown.length - contentMd.length).split("\n").length - 1 : 0;
      const env = {};
      const tokens = md.parse(contentMd, env);
      tokens.forEach(function(t) {
        if (t.map && t.block && t.nesting >= 0) t.attrSet("data-line", String(t.map[0] + 1 + offset));
      });
      html = md.renderer.render(tokens, md.options, env);
    } else {
      html = '<pre style="white-space: pre-wrap; word-break: break-word;">' + window.mvKit.escapeHtml(markdown) + "</pre>";
    }
    let fmPanel = "";
    if (frontmatter) {
      const lines = frontmatter.split("\n").filter((l) => l.trim());
      let rows = "";
      lines.forEach((line) => {
        const colonIdx = line.indexOf(":");
        if (colonIdx > 0) {
          const key = window.mvKit.escapeHtml(line.substring(0, colonIdx).trim());
          const rawVal = line.substring(colonIdx + 1).trim();
          let val = window.mvKit.escapeHtml(rawVal);
          if (rawVal === "active") val = '<span style="color:#4ec9b0">\u25CF</span> ' + val;
          else if (rawVal === "deprecated") val = '<span style="color:#f44747">\u25CF</span> ' + val;
          else if (rawVal === "high") val = '<span style="color:#4ec9b0">\u25B2</span> ' + val;
          else if (rawVal === "low") val = '<span style="color:#ce9178">\u25BC</span> ' + val;
          if (rawVal.startsWith("[") && rawVal.endsWith("]")) {
            const items = rawVal.slice(1, -1).split(",").map((s) => window.mvKit.escapeHtml(s.trim())).filter(Boolean);
            val = items.map((i) => '<span style="background:var(--bg-tertiary);padding:1px 5px;border-radius:3px;font-size:10px;margin:1px;">' + i + "</span>").join(" ");
          }
          rows += '<tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">' + key + '</td><td style="padding:2px 8px;font-size:10px;">' + val + "</td></tr>";
        }
      });
      fmPanel = `<details class="frontmatter-panel" open>
                        <summary style="cursor:pointer;font-size:10px;color:#808080;padding:6px 10px;background:var(--bg-secondary);border:1px solid var(--border-color);border-radius:4px 4px 0 0;user-select:none;">
                            <span style="font-weight:600;">Metadata</span>
                        </summary>
                        <div style="background:var(--bg-secondary);border:1px solid var(--border-color);border-top:none;border-radius:0 0 4px 4px;padding:4px 0;">
                            <table style="width:100%;border-collapse:collapse;">${rows}</table>
                        </div>
                    </details>`;
    }
    html = sanitizeMarkdownHTML(fmPanel + '<div class="markdown-body">' + html + "</div>");
    DOM.rendered.innerHTML = html;
    resolveLocalURLs();
    const mermaidBlocks = DOM.rendered.querySelectorAll("pre code.language-mermaid");
    mermaidBlocks.forEach((code, idx) => {
      const pre = code.parentElement;
      const mermaidSource = code.textContent;
      if (mermaidSource.includes("%%INTERACTIVE")) {
        const container = document.createElement("div");
        container.className = "mermaid-canvas";
        container.setAttribute("data-source", mermaidSource);
        container.id = "mermaid-canvas-" + idx;
        const viewportH = window.innerHeight || 800;
        const canvasH = Math.max(viewportH - 120, 500);
        container.style.cssText = "width:100%;height:" + canvasH + "px;border:1px solid var(--border-color);border-radius:6px;margin:12px 0;position:relative;overflow:hidden;";
        pre.replaceWith(container);
        container.innerHTML = '<div style="display:flex;align-items:center;justify-content:center;height:100%;gap:8px;"><div style="width:20px;height:20px;border:2px solid #569cd6;border-top-color:transparent;border-radius:50%;animation:spin 1s linear infinite;"></div><span style="color:#808080;font-size:11px;">Building interactive graph...</span></div>';
        setTimeout(() => initMermaidCanvas(container, mermaidSource), 200);
      } else {
        const div = document.createElement("div");
        div.className = "mermaid";
        div.textContent = mermaidSource;
        div.setAttribute("data-source", mermaidSource);
        pre.replaceWith(div);
      }
    });
    if (typeof Prism !== "undefined") {
      setTimeout(() => {
        DOM.rendered.querySelectorAll("pre code").forEach((el) => {
          Prism.highlightElement(el);
        });
      }, 0);
    }
    if (typeof mermaid !== "undefined") {
      const runId = ++mermaidRunId;
      setTimeout(() => {
        drawMermaidDiagrams(runId);
      }, 0);
    }
    extractHeadings();
    updateStats();
    sendToSwift("contentChanged", {
      markdown: state.markdown,
      html: DOM.rendered.innerHTML
    });
  } catch (error) {
    console.error("Render error:", error);
  } finally {
    state.isRendering = false;
  }
}
let headingIdCounter = 0;
function extractHeadings() {
  const headings = [];
  const headingMap = /* @__PURE__ */ new Map();
  DOM.rendered.querySelectorAll("h1, h2, h3, h4, h5, h6").forEach((heading) => {
    const level = parseInt(heading.tagName[1]);
    let id = heading.id;
    if (!id) {
      let text = heading.textContent.trim();
      id = text.toLowerCase().replace(/\s+/g, "-").replace(/[^\p{L}\p{N}-]/gu, "").replace(/--+/g, "-").replace(/^-+|-+$/g, "") || `heading-${headingIdCounter++}`;
      if (headingMap.has(id)) {
        let count = headingMap.get(id) + 1;
        headingMap.set(id, count);
        id = `${id}-${count}`;
      } else {
        headingMap.set(id, 1);
      }
      heading.id = id;
    }
    headings.push({
      id,
      level,
      text: heading.textContent.trim()
    });
  });
  state.headings = headings;
  updateTOCStatus();
  sendToSwift("headingsUpdated", headings);
}
function updateTOCStatus() {
  const items = state.headings.slice(0, 5);
  if (items.length === 0) {
    DOM.tocStatus.innerHTML = "";
  } else {
    const tocHTML = "Headings: " + items.map((h) => `<strong>${window.mvKit.escapeHtml(h.text)}</strong>`).join(" \u2192 ");
    DOM.tocStatus.innerHTML = tocHTML;
  }
}
function setupHeadingObserver() {
  const options = {
    root: DOM.rendered,
    rootMargin: "-80px 0px -66% 0px",
    threshold: 0
  };
  const observer = new IntersectionObserver((entries) => {
    let activeId = null;
    for (let entry of entries) {
      if (entry.isIntersecting && entry.target.id) {
        activeId = entry.target.id;
        break;
      }
    }
    if (activeId !== state.activeHeadingId) {
      state.activeHeadingId = activeId;
      sendToSwift("scrollPosition", { activeHeadingId: activeId });
    }
  }, options);
  setTimeout(() => {
    DOM.rendered.querySelectorAll("h1, h2, h3, h4, h5, h6").forEach((heading) => {
      observer.observe(heading);
    });
  }, 100);
}
;
function updateStats() {
  const text = DOM.editor.value;
  const words = text.trim().split(/\s+/).filter((w) => w.length > 0).length;
  const chars = text.length;
  DOM.statusWords.textContent = `${words} words`;
  DOM.statusChars.textContent = `${chars} chars`;
}
(function initFontSlider() {
  const slider = document.getElementById("font-slider");
  if (!slider) return;
  const saved = localStorage.getItem("markview-font-size");
  if (saved) {
    slider.value = saved;
    applyFontSize(parseFloat(saved));
  }
  function reportSize(size) {
    try {
      window.mvBridge.send("editorFontSize", { size }, "bridge");
    } catch (e) {
    }
  }
  reportSize(parseFloat(slider.value));
  slider.addEventListener("input", function() {
    const size = parseFloat(this.value);
    applyFontSize(size);
    localStorage.setItem("markview-font-size", size);
    reportSize(size);
  });
})();
window.mvSetUIScale = function(scale) {
  const value = Number(scale) > 0 ? String(Number(scale)) : "1";
  document.documentElement.style.setProperty("--ui-scale", value);
  document.querySelectorAll("iframe").forEach(function(frame) {
    try {
      frame.contentDocument.documentElement.style.setProperty("--ui-scale", value);
    } catch (e) {
    }
  });
};
function applyFontSize(size) {
  document.documentElement.style.setProperty("--base-font-size", size + "px");
  const rendered2 = document.getElementById("editor-rendered");
  if (rendered2) rendered2.style.fontSize = size + "px";
  if (typeof window.setCodeBaseSize === "function") window.setCodeBaseSize(size);
}
let turndownService = null;
function initTurndown() {
  if (typeof TurndownService === "undefined") return;
  turndownService = new TurndownService({
    headingStyle: "atx",
    codeBlockStyle: "fenced",
    bulletListMarker: "-",
    emDelimiter: "*"
  });
  if (typeof turndownPluginGfm !== "undefined") {
    turndownService.use(turndownPluginGfm.gfm);
  }
  turndownService.addRule("mermaid", {
    filter: function(node) {
      return node.classList && node.classList.contains("mermaid") || node.classList && node.classList.contains("mermaid-canvas");
    },
    replacement: function(content, node) {
      const source = node.getAttribute("data-source") || node.textContent;
      return "\n```mermaid\n" + source.trim() + "\n```\n";
    }
  });
  turndownService.addRule("wikilink", {
    filter: function(node) {
      return node.nodeName === "A" && node.classList.contains("wikilink");
    },
    replacement: function(content, node) {
      return node.getAttribute("data-raw") || "[[" + node.getAttribute("data-wikilink") + "]]";
    }
  });
  turndownService.addRule("math", {
    filter: function(node) {
      return node.classList && (node.classList.contains("math-inline") || node.classList.contains("math-block"));
    },
    replacement: function(content, node) {
      const tex = node.getAttribute("data-tex") || "";
      return node.classList.contains("math-block") ? "\n\n$$\n" + tex + "\n$$\n\n" : "$" + tex + "$";
    }
  });
  turndownService.addRule("svg", {
    filter: "svg",
    replacement: function() {
      return "";
    }
  });
}
function toggleMode() {
  if (state.mode === "insight") return;
  if (state.mode === "source") {
    switchToPreview();
  } else {
    switchToSource();
  }
}
function switchToPreview() {
  state.mode = "preview";
  if (typeof leaveInsightView === "function") leaveInsightView();
  DOM.editorPane.style.display = "none";
  DOM.previewPane.style.display = "flex";
  DOM.statusMode.textContent = "WYSIWYG";
  document.getElementById("wysiwyg-toolbar").style.display = "flex";
  document.getElementById("mode-toggle").textContent = "Source \u2197";
  renderMarkdown();
  setupHeadingObserver();
  updateStats();
}
function switchToSource() {
  state.mode = "source";
  if (typeof leaveInsightView === "function") leaveInsightView();
  syncWysiwygToMarkdown();
  DOM.editorPane.style.display = "flex";
  DOM.previewPane.style.display = "none";
  DOM.statusMode.textContent = "Source";
  document.getElementById("wysiwyg-toolbar").style.display = "flex";
  document.getElementById("mode-toggle").textContent = "WYSIWYG \u2197";
  updateStats();
  DOM.editor.focus();
}
let wysiwygDirty = false;
function syncWysiwygToMarkdown() {
  if (!wysiwygDirty) return;
  if (!turndownService) initTurndown();
  if (!turndownService) return;
  const html = MarkViewDocumentFiles.withOriginalPaths(DOM.rendered.innerHTML);
  if (!html || html.includes("editor-empty")) return;
  const md2 = turndownService.turndown(html);
  if (md2 && md2.trim().length > 0) {
    DOM.editor.value = md2;
    state.markdown = md2;
  }
}
let wysiwygTimer = null;
const rendered = document.getElementById("editor-rendered");
rendered.addEventListener("input", function() {
  wysiwygDirty = true;
});
function fmtCmd(cmd, value) {
  document.execCommand(cmd, false, value || null);
  rendered.focus();
}
function fmtHeading() {
  const sel = window.getSelection();
  if (!sel.rangeCount) return;
  const node = sel.anchorNode.parentElement;
  const tag = node.tagName;
  let next = "H2";
  if (tag === "H2") next = "H3";
  else if (tag === "H3") next = "H4";
  else if (tag === "H4") next = "P";
  document.execCommand("formatBlock", false, next);
}
function fmtBlock(tag) {
  document.execCommand("formatBlock", false, tag);
  rendered.focus();
}
function fmtLink() {
  const url = prompt("URL:");
  if (url) document.execCommand("createLink", false, url);
}
function fmtHR() {
  document.execCommand("insertHorizontalRule");
  rendered.focus();
}
function fmtImage() {
  const url = prompt("Image URL or filename:");
  if (!url) return;
  const alt = prompt("Alt text:", "image") || "image";
  document.execCommand("insertHTML", false, `<img src="${url}" alt="${alt}" style="max-width:100%">`);
  rendered.focus();
}
function fmtCodeBlock() {
  const lang = prompt("Language (e.g. python, javascript):", "") || "";
  const placeholder = "// code here";
  const html = `<pre><code class="language-${lang}">${placeholder}</code></pre><p><br></p>`;
  document.execCommand("insertHTML", false, html);
  rendered.focus();
}
function fmtMermaid() {
  const types = {
    "1": "graph TD\\n    A[Start] --> B[Process]\\n    B --> C[End]",
    "2": "sequenceDiagram\\n    Alice->>Bob: Hello\\n    Bob-->>Alice: Hi",
    "3": 'pie title Distribution\\n    "A" : 40\\n    "B" : 30\\n    "C" : 30',
    "4": "flowchart LR\\n    A --> B --> C"
  };
  const choice = prompt("Mermaid diagram type:\\n1 = Flowchart\\n2 = Sequence\\n3 = Pie\\n4 = Horizontal flow\\n\\nEnter number:", "1");
  const code = types[choice] || types["1"];
  const html = `<pre><code class="language-mermaid">${code.replace(/\\n/g, "\n")}</code></pre><p><br></p>`;
  document.execCommand("insertHTML", false, html);
  wysiwygDirty = true;
  setTimeout(() => {
    renderMarkdown();
  }, 100);
}
function fmtTable() {
  const cols = parseInt(prompt("Columns:", "3")) || 3;
  const rows = parseInt(prompt("Rows:", "3")) || 3;
  let html = "<table><thead><tr>";
  for (let c = 0; c < cols; c++) html += `<th>Header ${c + 1}</th>`;
  html += "</tr></thead><tbody>";
  for (let r = 0; r < rows; r++) {
    html += "<tr>";
    for (let c = 0; c < cols; c++) html += "<td>&nbsp;</td>";
    html += "</tr>";
  }
  html += "</tbody></table><p><br></p>";
  document.execCommand("insertHTML", false, html);
  rendered.focus();
}
function fmtCode() {
  const sel = window.getSelection();
  if (!sel.rangeCount) return;
  const range = sel.getRangeAt(0);
  const code = document.createElement("code");
  range.surroundContents(code);
}
window.fmtCmd = function(cmd, value) {
  if (cmd === "code") {
    fmtCode();
    return;
  }
  document.execCommand(cmd, false, value || null);
  rendered.focus();
};
let formatBarSelectedText = "";
document.addEventListener("selectionchange", function() {
  const sel = window.getSelection();
  const bar = document.getElementById("format-bar");
  if (state.fileType !== "markdown" || !sel.rangeCount || sel.isCollapsed || !rendered.contains(sel.anchorNode)) {
    bar.classList.remove("visible");
    formatBarSelectedText = "";
    return;
  }
  const range = sel.getRangeAt(0);
  const rect = range.getBoundingClientRect();
  bar.style.left = Math.max(8, rect.left + rect.width / 2 - 120) + "px";
  bar.style.top = Math.max(4, rect.top - 38) + "px";
  bar.classList.add("visible");
  formatBarSelectedText = sel.toString().trim();
});
function currentSourceSelection() {
  if (state.mode !== "source" || !DOM.editor) return "";
  const start = DOM.editor.selectionStart;
  const end = DOM.editor.selectionEnd;
  if (typeof start !== "number" || start === end) return "";
  return DOM.editor.value.substring(start, end).trim();
}
function saveFile() {
  if (wysiwygDirty) {
    syncWysiwygToMarkdown();
  }
  sendToSwift("contentChanged", { markdown: DOM.editor.value });
  sendToSwift("saveRequested", {});
  wysiwygDirty = false;
}
window.mvSetDocument = function(id) {
  const next = id || "";
  if (next !== (window.mvDocumentId || "") && wysiwygDirty && state.fileType === "markdown") {
    if (state.mode === "preview") syncWysiwygToMarkdown();
    sendToSwift("contentChanged", { markdown: DOM.editor.value });
    wysiwygDirty = false;
  }
  window.mvDocumentId = next;
};
function translateWholeDocument(targetLang) {
  if (wysiwygDirty) {
    syncWysiwygToMarkdown();
  }
  sendToSwift("translateRequested", { markdown: DOM.editor.value, targetLang });
}
function refreshFile() {
  sendToSwift("refreshRequested", {});
}
rendered.addEventListener("keydown", function(e) {
  if (e.metaKey || e.ctrlKey) {
    if (e.key === "b") {
      e.preventDefault();
      fmtCmd("bold");
    }
    if (e.key === "i") {
      e.preventDefault();
      fmtCmd("italic");
    }
    if (e.key === "k") {
      e.preventDefault();
      fmtLink();
    }
    if (e.key === "s") {
      e.preventDefault();
      saveFile();
    }
    if (e.key === "r") {
      e.preventDefault();
      refreshFile();
    }
  }
  if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key === "p") {
    e.preventDefault();
    switchToSource();
  }
});
DOM.editor.addEventListener("keydown", function(e) {
  if ((e.metaKey || e.ctrlKey) && e.key === "s") {
    e.preventDefault();
    saveFile();
  }
});
document.addEventListener("keydown", function(e) {
  if (e.key === "Escape" && state.mode === "source") {
    switchToPreview();
  }
});
;
const TRANSLATE_TARGETS = { translate_ru: "Russian", translate_en: "English" };
function selectionAction(action) {
  let selectedText = formatBarSelectedText;
  if (!selectedText) {
    const sel = window.getSelection();
    if (sel.rangeCount && !sel.isCollapsed) {
      selectedText = sel.toString().trim();
    }
  }
  if (!selectedText) {
    selectedText = currentSourceSelection();
  }
  let title = "Result";
  if (action === "translate_ru") title = "\u041F\u0435\u0440\u0435\u0432\u043E\u0434 \u043D\u0430 \u0440\u0443\u0441\u0441\u043A\u0438\u0439";
  else if (action === "translate_en") title = "Translation to English";
  else if (action === "explain") title = "Explanation";
  if (!selectedText) {
    if (TRANSLATE_TARGETS[action]) proposeWholeDocumentTranslation(action, title);
    return;
  }
  document.getElementById("format-bar").classList.remove("visible");
  showActionPopup(title, '<span class="action-popup-loading">Processing...</span>');
  sendToSwift("selectionAction", { action, text: selectedText });
}
let featureText = "";
function showFeatureMenu() {
  let text = formatBarSelectedText;
  if (!text) {
    const sel = window.getSelection();
    if (sel.rangeCount && !sel.isCollapsed) text = sel.toString().trim();
  }
  if (!text) text = currentSourceSelection();
  if (!text) return;
  featureText = text;
  const bar = document.getElementById("format-bar");
  const menu = document.getElementById("feature-menu");
  const r = bar.getBoundingClientRect();
  menu.style.left = Math.max(8, Math.min(r.left, window.innerWidth - 230)) + "px";
  menu.style.top = Math.min(r.bottom + 4, window.innerHeight - 330) + "px";
  menu.classList.add("visible");
  const research = isResearchDocument();
  document.getElementById("feature-comment").style.display = research ? "" : "none";
  document.getElementById("feature-comment-sep").style.display = research ? "" : "none";
  const input = document.getElementById("feature-ask");
  input.placeholder = research ? "Ask AI, or write a comment to revise this passage\u2026" : "Ask AI about the selection\u2026";
  input.value = "";
  setTimeout(function() {
    input.focus();
  }, 0);
}
function isResearchDocument() {
  const md2 = typeof state !== "undefined" && state.markdown || DOM.editor && DOM.editor.value || "";
  const fm = md2.match(/^---\n([\s\S]*?)\n---\n/);
  return !!fm && /^type:\s*["']?research["']?\s*$/m.test(fm[1]);
}
function hideFeatureMenu() {
  document.getElementById("feature-menu").classList.remove("visible");
}
function featureAction(action) {
  let question = "";
  if (action === "ask" || action === "comment") {
    question = document.getElementById("feature-ask").value.trim();
    if (!question) return;
  }
  if (!featureText) return;
  hideFeatureMenu();
  document.getElementById("format-bar").classList.remove("visible");
  sendToSwift("featureAction", { action, text: featureText, question });
}
document.addEventListener("mousedown", function(e) {
  const menu = document.getElementById("feature-menu");
  if (menu && menu.classList.contains("visible") && !menu.contains(e.target)) hideFeatureMenu();
});
function proposeWholeDocumentTranslation(action, title) {
  const targetLang = TRANSLATE_TARGETS[action];
  if (!targetLang) return;
  if (state.fileType !== "markdown") return;
  const markdown = DOM.editor ? DOM.editor.value : "";
  if (!markdown.trim()) return;
  document.getElementById("format-bar").classList.remove("visible");
  const approxKb = Math.max(1, Math.round(markdown.length / 1024));
  showActionPopup(
    title,
    "<p>Nothing is selected.</p><p>Translate the <b>entire document</b> (~" + approxKb + " KB) to " + targetLang + '? The translation opens in a new tab as an unsaved copy \u2014 this file is not modified.</p><div class="action-popup-actions"><button type="button" id="translate-doc-confirm">Translate whole document</button><button type="button" id="translate-doc-cancel">Cancel</button></div>'
  );
  document.getElementById("translate-doc-confirm").addEventListener("click", function() {
    closeActionPopup();
    translateWholeDocument(targetLang);
  });
  document.getElementById("translate-doc-cancel").addEventListener("click", closeActionPopup);
}
function showActionPopup(title, htmlContent) {
  document.getElementById("action-popup-title").textContent = title;
  document.getElementById("action-popup-content").innerHTML = htmlContent;
  document.getElementById("action-popup").classList.add("visible");
  document.getElementById("action-popup-backdrop").classList.add("visible");
}
function closeActionPopup() {
  document.getElementById("action-popup").classList.remove("visible");
  document.getElementById("action-popup-backdrop").classList.remove("visible");
}
window.showSelectionResult = function(title, markdownContent) {
  let html;
  if (typeof md !== "undefined") {
    html = md.render(markdownContent);
  } else {
    html = "<pre>" + window.mvKit.escapeHtml(markdownContent || "") + "</pre>";
  }
  if (typeof window.sanitizeMarkdownHTML === "function") {
    html = window.sanitizeMarkdownHTML(html);
  }
  showActionPopup(title, html);
  const content = document.getElementById("action-popup-content");
  if (typeof Prism !== "undefined") {
    content.querySelectorAll("pre code").forEach((el) => Prism.highlightElement(el));
  }
};
document.addEventListener("keydown", function(e) {
  if (e.key === "Escape" && document.getElementById("action-popup").classList.contains("visible")) {
    closeActionPopup();
  }
});
const findState = {
  visible: false,
  caseSensitive: false,
  useRegex: false,
  matches: [],
  // Array of {node, start, end} or Range objects
  currentIndex: -1,
  highlights: []
  // DOM mark elements
};
function openFind() {
  findState.visible = true;
  const bar = document.getElementById("find-bar");
  bar.classList.add("visible");
  const input = document.getElementById("find-input");
  input.focus();
  input.select();
}
function closeFind() {
  findState.visible = false;
  document.getElementById("find-bar").classList.remove("visible");
  clearHighlights();
  document.getElementById("find-count").textContent = "";
}
function toggleFindCase() {
  findState.caseSensitive = !findState.caseSensitive;
  const btn = document.getElementById("find-case-btn");
  btn.style.color = findState.caseSensitive ? "var(--accent-primary)" : "";
  btn.style.borderBottom = findState.caseSensitive ? "2px solid var(--accent-primary)" : "";
  performFind();
}
function toggleFindRegex() {
  findState.useRegex = !findState.useRegex;
  const btn = document.getElementById("find-regex-btn");
  btn.style.color = findState.useRegex ? "var(--accent-primary)" : "";
  btn.style.borderBottom = findState.useRegex ? "2px solid var(--accent-primary)" : "";
  performFind();
}
function clearHighlights() {
  findState.highlights.forEach((mark) => {
    const parent = mark.parentNode;
    if (parent) {
      parent.replaceChild(document.createTextNode(mark.textContent), mark);
      parent.normalize();
    }
  });
  findState.highlights = [];
  findState.matches = [];
  findState.currentIndex = -1;
}
function performFind() {
  clearHighlights();
  const query = document.getElementById("find-input").value;
  if (!query) {
    document.getElementById("find-count").textContent = "";
    return;
  }
  const container = state.mode === "source" || state.mode === "structured-source" ? null : DOM.rendered;
  if (!container) {
    findInTextarea(query);
    return;
  }
  let regex;
  try {
    const flags = findState.caseSensitive ? "g" : "gi";
    regex = findState.useRegex ? new RegExp(query, flags) : new RegExp(escapeRegex(query), flags);
  } catch (e) {
    document.getElementById("find-count").textContent = "Invalid regex";
    return;
  }
  const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT, null);
  const textNodes = [];
  let node;
  while (node = walker.nextNode()) {
    if (node.textContent.length > 0) textNodes.push(node);
  }
  for (const textNode of textNodes) {
    const text = textNode.textContent;
    const matches = [...text.matchAll(regex)];
    if (matches.length === 0) continue;
    const frag = document.createDocumentFragment();
    let lastIdx = 0;
    for (const match of matches) {
      const start = match.index;
      const end = start + match[0].length;
      if (start > lastIdx) {
        frag.appendChild(document.createTextNode(text.substring(lastIdx, start)));
      }
      const mark = document.createElement("mark");
      mark.className = "find-highlight";
      mark.textContent = text.substring(start, end);
      frag.appendChild(mark);
      findState.highlights.push(mark);
      lastIdx = end;
    }
    if (lastIdx < text.length) {
      frag.appendChild(document.createTextNode(text.substring(lastIdx)));
    }
    textNode.parentNode.replaceChild(frag, textNode);
  }
  findState.matches = findState.highlights;
  const count = findState.matches.length;
  document.getElementById("find-count").textContent = count > 0 ? `${count} found` : "No results";
  if (count > 0) {
    findState.currentIndex = 0;
    highlightCurrent();
  }
}
function findInTextarea(query) {
  const text = DOM.editor.value;
  let regex;
  try {
    const flags = findState.caseSensitive ? "g" : "gi";
    regex = findState.useRegex ? new RegExp(query, flags) : new RegExp(escapeRegex(query), flags);
  } catch (e) {
    document.getElementById("find-count").textContent = "Invalid regex";
    return;
  }
  const matches = [...text.matchAll(regex)];
  document.getElementById("find-count").textContent = matches.length > 0 ? `${matches.length} found` : "No results";
  if (matches.length > 0) {
    findState.matches = matches;
    findState.currentIndex = 0;
    selectTextareaMatch(0);
  }
}
function selectTextareaMatch(index) {
  if (index < 0 || index >= findState.matches.length) return;
  const match = findState.matches[index];
  DOM.editor.focus();
  DOM.editor.setSelectionRange(match.index, match.index + match[0].length);
  const lineHeight = parseInt(getComputedStyle(DOM.editor).lineHeight) || 18;
  const linesAbove = DOM.editor.value.substring(0, match.index).split("\n").length;
  DOM.editor.scrollTop = (linesAbove - 3) * lineHeight;
  document.getElementById("find-count").textContent = `${index + 1}/${findState.matches.length}`;
}
function highlightCurrent() {
  findState.highlights.forEach((m) => m.className = "find-highlight");
  if (findState.currentIndex >= 0 && findState.currentIndex < findState.highlights.length) {
    const current = findState.highlights[findState.currentIndex];
    current.className = "find-highlight find-highlight-active";
    current.scrollIntoView({ behavior: "smooth", block: "center" });
    document.getElementById("find-count").textContent = `${findState.currentIndex + 1}/${findState.highlights.length}`;
  }
}
function findNext() {
  if (findState.matches.length === 0) return;
  findState.currentIndex = (findState.currentIndex + 1) % findState.matches.length;
  if (state.mode === "source" || state.mode === "structured-source") {
    selectTextareaMatch(findState.currentIndex);
  } else {
    highlightCurrent();
  }
}
function findPrev() {
  if (findState.matches.length === 0) return;
  findState.currentIndex = (findState.currentIndex - 1 + findState.matches.length) % findState.matches.length;
  if (state.mode === "source" || state.mode === "structured-source") {
    selectTextareaMatch(findState.currentIndex);
  } else {
    highlightCurrent();
  }
}
function escapeRegex(str) {
  return str.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
document.addEventListener("keydown", function(e) {
  if ((e.metaKey || e.ctrlKey) && e.key === "f") {
    e.preventDefault();
    if (state.mode === "code" && window.codeViewOpenSearch) {
      window.codeViewOpenSearch();
      return;
    }
    openFind();
  }
  if (e.key === "Escape" && findState.visible) {
    closeFind();
  }
});
document.getElementById("find-input").addEventListener("input", function() {
  performFind();
});
document.getElementById("find-input").addEventListener("keydown", function(e) {
  if (e.key === "Enter") {
    e.preventDefault();
    if (e.shiftKey) {
      findPrev();
    } else {
      findNext();
    }
  }
});
;
function applyTheme(id, accent, definition) {
  const theme = MarkViewThemes.apply(id, accent, definition);
  state.theme = theme.mode;
  try {
    const insight = document.getElementById("insight-iframe");
    if (insight && insight.contentDocument) insight.contentDocument.documentElement.setAttribute("data-theme", theme.mode);
  } catch (e) {
  }
  if (typeof mermaid !== "undefined") {
    try {
      mermaid.initialize(Object.assign({ startOnLoad: false, securityLevel: "strict" }, MarkViewThemes.mermaid()));
    } catch (e) {
    }
  }
}
function sendToSwift(type, payload) {
  window.mvBridge.send(type, payload, "bridge");
}
window.addEventListener("error", function(event) {
  try {
    sendToSwift("jsError", {
      where: "window.error",
      message: String(event.message || event.error || "unknown"),
      source: String(event.filename || "inline"),
      lineno: event.lineno || 0,
      colno: event.colno || 0,
      stack: event.error && event.error.stack ? String(event.error.stack) : ""
    });
  } catch (_) {
  }
});
window.addEventListener("unhandledrejection", function(event) {
  try {
    const reason = event.reason;
    sendToSwift("jsError", {
      where: "unhandledrejection",
      message: reason && reason.message ? String(reason.message) : String(reason),
      source: "promise",
      lineno: 0,
      colno: 0,
      stack: reason && reason.stack ? String(reason.stack) : ""
    });
  } catch (_) {
  }
});
window.setContent = function(markdown) {
  DOM.editor.value = markdown;
  state.markdown = markdown;
  wysiwygDirty = false;
  initTurndown();
  switchToPreview();
};
;
window.setStructuredContent = function(content, fileType) {
  DOM.editor.value = content;
  state.markdown = content;
  state.fileType = fileType;
  wysiwygDirty = false;
  switchToStructuredView();
};
function switchToStructuredView() {
  state.mode = "structured";
  if (typeof leaveInsightView === "function") leaveInsightView();
  state.markdown = DOM.editor.value;
  DOM.editorPane.style.display = "none";
  DOM.previewPane.style.display = "flex";
  DOM.previewPane.style.flexDirection = "column";
  DOM.rendered.contentEditable = "false";
  DOM.statusMode.textContent = state.fileType.toUpperCase();
  document.getElementById("mode-toggle").textContent = "Source \u2197";
  document.getElementById("wysiwyg-toolbar").style.display = "none";
  renderStructuredContent();
}
function switchToStructuredSource() {
  state.mode = "structured-source";
  if (state.fileType === "json" || state.fileType === "yaml") {
    openStructSourceEditor();
    return;
  }
  if (typeof leaveInsightView === "function") leaveInsightView();
  DOM.editorPane.style.display = "flex";
  DOM.previewPane.style.display = "none";
  DOM.statusMode.textContent = state.fileType.toUpperCase() + " Source";
  document.getElementById("wysiwyg-toolbar").style.display = "none";
  document.getElementById("mode-toggle").textContent = "Tree \u2197";
  const currentSize = getComputedStyle(DOM.rendered).fontSize;
  if (currentSize) DOM.editor.style.fontSize = currentSize;
  DOM.editor.focus();
}
function renderStructuredContent() {
  if (state.fileType === "canvas") {
    if (typeof window.renderCanvasView === "function") window.renderCanvasView();
    return;
  }
  if (typeof window.leaveCanvasView === "function") window.leaveCanvasView();
  let html = "";
  try {
    if (state.fileType === "json") {
      const parsed = JSON.parse(state.markdown);
      html = '<div class="struct-tree struct-editable">' + renderStructToolbar() + renderJSON(parsed, "", true, []) + "</div>";
      extractStructHeadings(parsed, "json");
    } else if (state.fileType === "xml") {
      const parser = new DOMParser();
      const doc = parser.parseFromString(state.markdown, "text/xml");
      const parseError = doc.querySelector("parsererror");
      if (parseError) throw new Error(parseError.textContent);
      html = '<div class="struct-tree">' + renderStructToolbar() + renderXML(doc.documentElement, "", true) + "</div>";
      extractStructHeadings(doc.documentElement, "xml");
    } else if (state.fileType === "yaml") {
      const parsed = jsyaml.load(state.markdown);
      html = '<div class="struct-tree struct-editable">' + renderStructToolbar() + renderJSON(parsed, "", true, []) + "</div>";
      extractStructHeadings(parsed, "yaml");
    }
  } catch (e) {
    html = '<div class="struct-error">Parse Error: ' + window.mvKit.escapeHtml(e.message) + '</div><pre class="language-' + state.fileType + '" style="padding:12px;margin:0;overflow:auto;"><code>' + window.mvKit.escapeHtml(state.markdown) + "</code></pre>";
    if (typeof Prism !== "undefined") {
      setTimeout(() => Prism.highlightAllUnder(DOM.rendered), 50);
    }
  }
  wireStructEditing();
  const collapsed = collapsedStructPaths();
  DOM.rendered.innerHTML = html;
  DOM.rendered.querySelectorAll(".struct-toggle").forEach((el) => {
    el.addEventListener("click", () => toggleStructNode(el));
  });
  DOM.rendered.querySelectorAll("[data-struct-action]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const action = btn.getAttribute("data-struct-action");
      if (action === "foldAll") structFoldAll();
      else if (action === "unfoldAll") structUnfoldAll();
      else if (action === "format") structFormat();
      else if (action === "minify") structMinify();
      else if (action === "toggleMode") toggleStructMode();
    });
  });
  restoreCollapsedStructPaths(collapsed);
}
function renderStructToolbar() {
  return '<div class="struct-toolbar"><button data-struct-action="foldAll">Fold All</button><button data-struct-action="unfoldAll">Unfold All</button>' + (state.fileType !== "xml" ? '<button data-struct-action="format">Format</button>' : "") + (state.fileType !== "xml" ? '<button data-struct-action="minify">Minify</button>' : "") + '<span class="spacer"></span>' + (state.fileType !== "xml" ? '<span class="struct-hint">Double-click a value or key to edit \xB7 hover a line for + and \xD7</span>' : "") + '<button data-struct-action="toggleMode">' + (state.mode === "structured" ? "Source \u2197" : "Tree \u2197") + "</button></div>";
}
function renderJSON(value, key, isLast, path) {
  path = path || [];
  if (value === null) return renderJSONLeaf(key, '<span class="struct-null struct-value">null</span>', isLast, path);
  if (typeof value === "boolean") return renderJSONLeaf(key, '<span class="struct-boolean struct-value">' + value + "</span>", isLast, path);
  if (typeof value === "number") return renderJSONLeaf(key, '<span class="struct-number struct-value">' + value + "</span>", isLast, path);
  if (typeof value === "string") return renderJSONLeaf(key, '<span class="struct-string struct-value">"' + window.mvKit.escapeHtml(value) + '"</span>', isLast, path);
  if (value instanceof Date) return renderJSONLeaf(key, '<span class="struct-string struct-value">' + window.mvKit.escapeHtml(value.toISOString()) + "</span>", isLast, path);
  const isArray = Array.isArray(value);
  const entries = isArray ? value.map((v, i) => [i, v]) : Object.entries(value);
  const open = isArray ? "[" : "{";
  const close = isArray ? "]" : "}";
  const count = entries.length;
  const id = "sn-" + Math.random().toString(36).substr(2, 8);
  let html = '<div class="struct-node" id="' + id + '" data-path="' + window.mvKit.escapeHtml(JSON.stringify(path)) + '" data-container="' + (isArray ? "array" : "object") + '">';
  html += '<div class="struct-line">';
  html += '<span class="struct-toggle" data-target="' + id + '-children">\u25BC</span>';
  if (key !== "") html += '<span class="struct-key">' + (typeof key === "number" ? key : '"' + window.mvKit.escapeHtml(String(key)) + '"') + '</span><span class="struct-colon">: </span>';
  html += '<span class="struct-bracket">' + open + "</span>";
  html += '<span class="struct-count">' + count + (count === 1 ? " item" : " items") + "</span>";
  html += structActions(path, true);
  html += "</div>";
  html += '<div class="struct-children" id="' + id + '-children">';
  entries.forEach(([k, v], i) => {
    html += renderJSON(v, k, i === entries.length - 1, path.concat([k]));
  });
  html += "</div>";
  html += '<div class="struct-line"><span class="struct-placeholder"></span><span class="struct-bracket">' + close + "</span>" + (isLast ? "" : '<span class="struct-comma">,</span>') + "</div>";
  html += "</div>";
  return html;
}
function renderJSONLeaf(key, valueHtml, isLast, path) {
  let html = '<div class="struct-node" data-path="' + window.mvKit.escapeHtml(JSON.stringify(path || [])) + '"><div class="struct-line"><span class="struct-placeholder"></span>';
  if (key !== "") html += '<span class="struct-key">' + (typeof key === "number" ? key : '"' + window.mvKit.escapeHtml(String(key)) + '"') + '</span><span class="struct-colon">: </span>';
  html += valueHtml;
  if (!isLast) html += '<span class="struct-comma">,</span>';
  html += structActions(path || [], false);
  html += "</div></div>";
  return html;
}
function structActions(path, isContainer) {
  let html = '<span class="struct-actions">';
  if (isContainer) html += '<button class="struct-act" data-act="add" title="Add an item">+</button>';
  if (path.length) html += '<button class="struct-act" data-act="delete" title="Delete">\xD7</button>';
  return html + "</span>";
}
function renderXML(node, indent, isLast) {
  if (node.nodeType === Node.TEXT_NODE) {
    const text = node.textContent.trim();
    if (!text) return "";
    return '<div class="struct-node"><div class="struct-line"><span class="struct-placeholder"></span><span class="struct-text">' + window.mvKit.escapeHtml(text) + "</span></div></div>";
  }
  if (node.nodeType === Node.COMMENT_NODE) {
    return '<div class="struct-node"><div class="struct-line"><span class="struct-placeholder"></span><span class="struct-comment">&lt;!-- ' + window.mvKit.escapeHtml(node.textContent) + " --&gt;</span></div></div>";
  }
  if (node.nodeType !== Node.ELEMENT_NODE) return "";
  const children = Array.from(node.childNodes).filter((c) => c.nodeType === Node.ELEMENT_NODE || c.nodeType === Node.TEXT_NODE && c.textContent.trim());
  const hasChildren = children.length > 0;
  const id = "sn-" + Math.random().toString(36).substr(2, 8);
  let attrs = "";
  for (const attr of node.attributes) {
    attrs += ' <span class="struct-attr-name">' + window.mvKit.escapeHtml(attr.name) + '</span>=<span class="struct-attr-value">"' + window.mvKit.escapeHtml(attr.value) + '"</span>';
  }
  let html = '<div class="struct-node" id="' + id + '">';
  html += '<div class="struct-line">';
  if (hasChildren) {
    html += '<span class="struct-toggle" data-target="' + id + '-children">\u25BC</span>';
  } else {
    html += '<span class="struct-placeholder"></span>';
  }
  html += '<span class="struct-bracket">&lt;</span><span class="struct-tag">' + window.mvKit.escapeHtml(node.tagName) + "</span>" + attrs;
  if (!hasChildren) {
    const textContent = node.textContent.trim();
    if (textContent && textContent.length < 80) {
      html += '<span class="struct-bracket">&gt;</span><span class="struct-text">' + window.mvKit.escapeHtml(textContent) + "</span>";
      html += '<span class="struct-bracket">&lt;/</span><span class="struct-tag">' + window.mvKit.escapeHtml(node.tagName) + '</span><span class="struct-bracket">&gt;</span>';
    } else {
      html += '<span class="struct-bracket"> /&gt;</span>';
    }
    html += "</div></div>";
    return html;
  }
  html += '<span class="struct-bracket">&gt;</span>';
  html += '<span class="struct-count">' + children.length + "</span>";
  html += "</div>";
  html += '<div class="struct-children" id="' + id + '-children">';
  children.forEach((child, i) => {
    html += renderXML(child, indent + "  ", i === children.length - 1);
  });
  html += "</div>";
  html += '<div class="struct-line"><span class="struct-placeholder"></span><span class="struct-bracket">&lt;/</span><span class="struct-tag">' + window.mvKit.escapeHtml(node.tagName) + '</span><span class="struct-bracket">&gt;</span></div>';
  html += "</div>";
  return html;
}
function toggleStructNode(toggleEl) {
  const targetId = toggleEl.getAttribute("data-target");
  const children = document.getElementById(targetId);
  if (!children) return;
  const collapsed = children.classList.toggle("collapsed");
  toggleEl.textContent = collapsed ? "\u25B6" : "\u25BC";
  toggleEl.classList.toggle("collapsed", collapsed);
}
window.revealStructure = function(pathJSON, line) {
  if (state.mode !== "structured") {
    if (typeof window.documentGotoLine === "function") window.documentGotoLine(line);
    return true;
  }
  const node = Array.from(DOM.rendered.querySelectorAll(".struct-node[data-path]")).find(function(n) {
    return n.getAttribute("data-path") === pathJSON;
  });
  if (!node) return false;
  for (let el = node.parentElement; el && el !== DOM.rendered; el = el.parentElement) {
    if (el.classList && el.classList.contains("struct-children") && el.classList.contains("collapsed")) {
      el.classList.remove("collapsed");
      const toggle = DOM.rendered.querySelector('.struct-toggle[data-target="' + el.id + '"]');
      if (toggle) {
        toggle.textContent = "\u25BC";
        toggle.classList.remove("collapsed");
      }
    }
  }
  const row = node.querySelector(".struct-line") || node;
  row.scrollIntoView({ block: "center" });
  row.classList.add("struct-revealed");
  setTimeout(function() {
    row.classList.remove("struct-revealed");
  }, 2200);
  return true;
};
window.structFoldAll = function() {
  DOM.rendered.querySelectorAll(".struct-children").forEach((el) => {
    el.classList.add("collapsed");
  });
  DOM.rendered.querySelectorAll(".struct-toggle").forEach((el) => {
    el.textContent = "\u25B6";
    el.classList.add("collapsed");
  });
};
window.structUnfoldAll = function() {
  DOM.rendered.querySelectorAll(".struct-children").forEach((el) => {
    el.classList.remove("collapsed");
  });
  DOM.rendered.querySelectorAll(".struct-toggle").forEach((el) => {
    el.textContent = "\u25BC";
    el.classList.remove("collapsed");
  });
};
window.structFormat = function() {
  try {
    if (state.fileType === "json") {
      const parsed = JSON.parse(state.markdown);
      const formatted = JSON.stringify(parsed, null, 2);
      DOM.editor.value = formatted;
      state.markdown = formatted;
      renderStructuredContent();
      sendToSwift("contentChanged", { markdown: formatted, html: "" });
    } else if (state.fileType === "yaml") {
      const formatted = window.MVData ? window.MVData.YAML.parseDocument(state.markdown).toString({ indent: 2 }) : jsyaml.dump(jsyaml.load(state.markdown), { indent: 2 });
      DOM.editor.value = formatted;
      state.markdown = formatted;
      renderStructuredContent();
      sendToSwift("contentChanged", { markdown: formatted, html: "" });
    }
  } catch (e) {
  }
};
window.structMinify = function() {
  try {
    if (state.fileType === "json") {
      const parsed = JSON.parse(state.markdown);
      const minified = JSON.stringify(parsed);
      DOM.editor.value = minified;
      state.markdown = minified;
      renderStructuredContent();
      sendToSwift("contentChanged", { markdown: minified, html: "" });
    }
  } catch (e) {
  }
};
window.toggleStructMode = function() {
  if (state.mode === "structured") {
    switchToStructuredSource();
  } else {
    closeStructSourceEditor();
    state.markdown = DOM.editor.value;
    switchToStructuredView();
  }
};
function extractStructHeadings(data, type) {
  const headings = [];
  let idCounter = 0;
  function addHeading(text, level) {
    headings.push({ id: "struct-h-" + idCounter++, level, text });
  }
  if (type === "json" || type === "yaml") {
    if (data && typeof data === "object" && !Array.isArray(data)) {
      for (const key of Object.keys(data)) {
        addHeading(key, 1);
        const val = data[key];
        if (val && typeof val === "object" && !Array.isArray(val)) {
          for (const k2 of Object.keys(val)) {
            addHeading(k2, 2);
          }
        }
      }
    }
  } else if (type === "xml") {
    addHeading(data.tagName, 1);
    for (const child of data.children) {
      addHeading(child.tagName, 2);
      for (const grandchild of child.children) {
        addHeading(grandchild.tagName, 3);
      }
    }
  }
  sendToSwift("headingsUpdated", headings);
}
const originalToggleMode = typeof toggleMode === "function" ? toggleMode : null;
function toggleModeWrapper() {
  if (state.mode === "insight") return;
  if (state.fileType !== "markdown") {
    toggleStructMode();
  } else if (originalToggleMode) {
    originalToggleMode();
  }
}
function collapsedStructPaths() {
  const out = /* @__PURE__ */ new Set();
  DOM.rendered.querySelectorAll(".struct-node[data-path] > .struct-children.collapsed").forEach((el) => out.add(el.parentElement.dataset.path));
  return out;
}
function restoreCollapsedStructPaths(paths) {
  if (!paths || !paths.size) return;
  DOM.rendered.querySelectorAll(".struct-node[data-path]").forEach((node) => {
    if (!paths.has(node.dataset.path)) return;
    const children = node.querySelector(":scope > .struct-children");
    const toggle = node.querySelector(":scope > .struct-line > .struct-toggle");
    if (children) children.classList.add("collapsed");
    if (toggle) {
      toggle.textContent = "\u25B6";
      toggle.classList.add("collapsed");
    }
  });
}
function jsonIndent(text) {
  const m = text.match(/\n([ \t]+)\S/);
  if (!m) return 2;
  return m[1][0] === "	" ? "	" : m[1].length;
}
function parseTypedValue(text) {
  const t = text.trim();
  if (t === "") return "";
  try {
    return JSON.parse(t);
  } catch (e) {
    return text;
  }
}
function loadYAMLLibrary() {
  if (window.MVData) return Promise.resolve(window.MVData);
  return new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = "vendor/js/data.bundle.js";
    script.onload = () => resolve(window.MVData);
    script.onerror = () => reject(new Error("YAML editing library missing"));
    document.head.appendChild(script);
  });
}
async function editStructured(change) {
  let next;
  if (state.fileType === "json") {
    const data = JSON.parse(state.markdown);
    const result = change({
      get: (path) => path.reduce((o, k) => o[k], data),
      set: (path, value) => {
        if (!path.length) return value;
        path.slice(0, -1).reduce((o, k) => o[k], data)[path[path.length - 1]] = value;
      },
      remove: (path) => {
        const parent = path.slice(0, -1).reduce((o, k) => o[k], data);
        const key = path[path.length - 1];
        if (Array.isArray(parent)) parent.splice(key, 1);
        else delete parent[key];
      },
      rename: (path, name) => {
        const parent = path.slice(0, -1).reduce((o, k) => o[k], data);
        const old = path[path.length - 1];
        const rebuilt = {};
        for (const k of Object.keys(parent)) rebuilt[k === old ? name : k] = parent[k];
        for (const k of Object.keys(parent)) delete parent[k];
        Object.assign(parent, rebuilt);
      }
    });
    next = JSON.stringify(result === void 0 ? data : result, null, jsonIndent(state.markdown)) + (state.markdown.endsWith("\n") ? "\n" : "");
  } else {
    const { YAML } = await loadYAMLLibrary();
    const doc = YAML.parseDocument(state.markdown);
    change({
      get: (path) => doc.getIn(path),
      set: (path, value) => {
        if (!path.length) doc.contents = doc.createNode(value);
        else doc.setIn(path, doc.createNode(value));
      },
      remove: (path) => doc.deleteIn(path),
      rename: (path, name) => {
        const parent = path.length > 1 ? doc.getIn(path.slice(0, -1), true) : doc.contents;
        const pair = parent && parent.items && parent.items.find((p) => p.key && (p.key.value ?? p.key) == path[path.length - 1]);
        if (pair && pair.key && typeof pair.key === "object" && "value" in pair.key) pair.key.value = name;
        else if (pair) pair.key = doc.createNode(name);
      }
    });
    next = doc.toString();
  }
  DOM.editor.value = next;
  state.markdown = next;
  renderStructuredContent();
  sendToSwift("contentChanged", { markdown: next, html: "" });
}
function inlineEditor(anchor, initial, onCommit) {
  const input = document.createElement("input");
  input.className = "struct-inline-input";
  input.value = initial;
  input.size = Math.max(8, Math.min(60, initial.length + 2));
  anchor.replaceWith(input);
  input.focus();
  input.select();
  let done = false;
  const finish = (commit) => {
    if (done) return;
    done = true;
    if (commit && input.value !== initial) onCommit(input.value);
    else renderStructuredContent();
  };
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      finish(true);
    } else if (e.key === "Escape") {
      e.preventDefault();
      finish(false);
    }
    e.stopPropagation();
  });
  input.addEventListener("blur", () => finish(true));
}
let structEditingWired = false;
function wireStructEditing() {
  if (structEditingWired) return;
  structEditingWired = true;
  DOM.rendered.addEventListener("dblclick", (e) => {
    if (state.mode !== "structured" || state.fileType !== "json" && state.fileType !== "yaml") return;
    const node = e.target.closest(".struct-node[data-path]");
    if (!node) return;
    const path = JSON.parse(node.dataset.path);
    const valueEl = e.target.closest(".struct-value");
    const keyEl = e.target.closest(".struct-key");
    if (valueEl && node.contains(valueEl)) {
      const raw = valueEl.classList.contains("struct-string") ? valueEl.textContent.replace(/^"|"$/g, "") : valueEl.textContent;
      const shown = valueEl.classList.contains("struct-string") ? JSON.stringify(raw) : raw;
      inlineEditor(valueEl, shown, (text) => editStructured((doc) => doc.set(path, parseTypedValue(text))).catch(showStructEditError));
    } else if (keyEl && path.length && typeof path[path.length - 1] === "string") {
      inlineEditor(keyEl, String(path[path.length - 1]), (name) => {
        if (!name.trim()) return renderStructuredContent();
        editStructured((doc) => doc.rename(path, name)).catch(showStructEditError);
      });
    }
  });
  DOM.rendered.addEventListener("click", (e) => {
    const button = e.target.closest(".struct-act");
    if (!button || state.mode !== "structured") return;
    e.stopPropagation();
    const node = button.closest(".struct-node[data-path]");
    const path = JSON.parse(node.dataset.path);
    if (button.dataset.act === "delete") {
      editStructured((doc) => doc.remove(path)).catch(showStructEditError);
    } else if (node.dataset.container === "array") {
      editStructured((doc) => {
        const list = doc.get(path);
        const length = Array.isArray(list) ? list.length : list && list.items ? list.items.length : 0;
        doc.set(path.concat([length]), null);
      }).catch(showStructEditError);
    } else {
      const placeholder = document.createElement("span");
      button.parentElement.appendChild(placeholder);
      inlineEditor(placeholder, "newKey", (name) => {
        if (!name.trim()) return renderStructuredContent();
        editStructured((doc) => doc.set(path.concat([name]), null)).catch(showStructEditError);
      });
    }
  });
}
function showStructEditError(error) {
  renderStructuredContent();
  const bar = document.createElement("div");
  bar.className = "struct-error";
  bar.textContent = "Could not change: " + (error && error.message || error);
  DOM.rendered.prepend(bar);
}
function structSourceStatus() {
  let bar = document.getElementById("struct-source-status");
  if (!bar) {
    bar = document.createElement("div");
    bar.id = "struct-source-status";
    bar.className = "struct-source-status";
    DOM.editorPane.insertBefore(bar, DOM.editorPane.firstChild);
    DOM.editor.addEventListener("input", () => {
      if (state.mode !== "structured-source") return;
      clearTimeout(bar.t);
      bar.t = setTimeout(validateStructSource, 250);
    });
  }
  return bar;
}
function validateStructSource() {
  const bar = structSourceStatus();
  const text = DOM.editor.value;
  try {
    if (state.fileType === "json") JSON.parse(text);
    else jsyaml.load(text);
    bar.textContent = "Valid " + state.fileType.toUpperCase();
    bar.className = "struct-source-status ok";
  } catch (e) {
    bar.textContent = state.fileType.toUpperCase() + ": " + e.message.split("\n")[0];
    bar.className = "struct-source-status bad";
  }
}
function openStructSourceEditor() {
  DOM.editorPane.style.display = "flex";
  DOM.previewPane.style.display = "none";
  DOM.statusMode.textContent = state.fileType.toUpperCase() + " Source";
  document.getElementById("wysiwyg-toolbar").style.display = "none";
  document.getElementById("mode-toggle").textContent = "Tree \u2197";
  const currentSize = getComputedStyle(DOM.rendered).fontSize;
  if (currentSize) DOM.editor.style.fontSize = currentSize;
  structSourceStatus().style.display = "";
  validateStructSource();
  DOM.editor.focus();
}
function closeStructSourceEditor() {
  const bar = document.getElementById("struct-source-status");
  if (bar) bar.style.display = "none";
}
const origSetStructuredForSource = window.setStructuredContent;
window.setStructuredContent = function(content, fileType) {
  closeStructSourceEditor();
  return origSetStructuredForSource(content, fileType);
};
;
const INSIGHT_LIB_FILES = {
  // libName: relative path under Resources/Editor/
  mermaid: "vendor/js/mermaid.min.js",
  chart: "vendor/js/chart-4.4.9.min.js",
  katex: "vendor/js/katex.min.js",
  "katex-auto": "vendor/js/auto-render.min.js",
  prism: "vendor/js/prism.min.js"
};
const KATEX_FONTS = [
  "KaTeX_Main-Regular.woff2",
  "KaTeX_Math-Italic.woff2"
];
function computeRequiredLibs(skeleton) {
  const libs = /* @__PURE__ */ new Set(["prism"]);
  if (!skeleton || !Array.isArray(skeleton.sections)) return libs;
  let needsMath = false;
  for (const s of skeleton.sections) {
    if (!s || typeof s.type !== "string") continue;
    if (s.type === "mermaidDiagram") libs.add("mermaid");
    if (s.type === "chartJsChart") libs.add("chart");
    if (s.metadata && s.metadata.hasMath === true) needsMath = true;
  }
  if (skeleton.metadata && skeleton.metadata.hasMath === true) needsMath = true;
  if (needsMath) {
    libs.add("katex");
    libs.add("katex-auto");
  }
  return libs;
}
async function ensureLibSource(libName) {
  if (state.insightLibBytes.has(libName)) {
    return state.insightLibBytes.get(libName);
  }
  const path = INSIGHT_LIB_FILES[libName];
  if (!path) {
    console.warn("[insight] unknown lib name:", libName);
    return null;
  }
  try {
    const resp = await fetch(path);
    if (!resp.ok) throw new Error("HTTP " + resp.status);
    const src = await resp.text();
    state.insightLibBytes.set(libName, src);
    return src;
  } catch (e) {
    console.warn("[insight] failed to fetch lib", libName, e);
    return null;
  }
}
async function ensureKatexCSSInline() {
  const cacheKey = "__katex-css-inline";
  if (state.insightLibBytes.has(cacheKey)) {
    return state.insightLibBytes.get(cacheKey);
  }
  try {
    const cssResp = await fetch("vendor/css/katex.min.css");
    if (!cssResp.ok) throw new Error("katex.min.css HTTP " + cssResp.status);
    let css = await cssResp.text();
    for (const fontName of KATEX_FONTS) {
      try {
        const fr = await fetch("vendor/css/fonts/" + fontName);
        if (!fr.ok) continue;
        const buf = await fr.arrayBuffer();
        let binary = "";
        const bytes = new Uint8Array(buf);
        for (let i = 0; i < bytes.byteLength; i++) binary += String.fromCharCode(bytes[i]);
        const b64 = btoa(binary);
        const dataUrl = "data:font/woff2;base64," + b64;
        const escapedName = fontName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        const re = new RegExp("url\\([^)]*" + escapedName + "[^)]*\\)", "g");
        css = css.replace(re, "url(" + dataUrl + ")");
      } catch (e) {
      }
    }
    state.insightLibBytes.set(cacheKey, css);
    return css;
  } catch (e) {
    console.warn("[insight] failed to inline KaTeX CSS:", e);
    return "";
  }
}
async function buildInsightSrcdoc(skeleton, libOrKatexCSS, maybeKatexCSSInline) {
  const katexCSSInline = typeof maybeKatexCSSInline === "string" ? maybeKatexCSSInline : typeof libOrKatexCSS === "string" ? libOrKatexCSS : "";
  const rawNonce = typeof window.__markviewInsightNonce === "string" && /^[A-Za-z0-9+/_=-]+$/.test(window.__markviewInsightNonce) ? window.__markviewInsightNonce : "";
  const scriptPolicy = rawNonce ? "'nonce-" + rawNonce + "'" : "'none'";
  const nonceAttr = rawNonce ? ' nonce="' + window.mvKit.escapeAttr(rawNonce) + '"' : "";
  const csp = "default-src 'none'; script-src " + scriptPolicy + "; style-src 'unsafe-inline'; connect-src 'none'; img-src data: blob:; font-src data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'";
  const title = window.mvKit.escapeHtml(skeleton && skeleton.title ? skeleton.title : "Insight");
  const libOrder = ["prism", "mermaid", "chart", "katex", "katex-auto"];
  const libsNeeded = computeRequiredLibs(skeleton);
  let libScripts = "";
  for (const libName of libOrder) {
    if (!libsNeeded.has(libName)) continue;
    const src = state.insightLibBytes && state.insightLibBytes.get(libName);
    if (typeof src === "string" && src.length > 0) {
      const safeSrc = src.replace(/<\/(script)/gi, "<\\/$1");
      libScripts += "<script" + nonceAttr + ">" + safeSrc + "<\/script>\n";
    }
  }
  const katexStyleBlock = katexCSSInline ? "<style>" + katexCSSInline + "</style>" : "";
  let sectionsHTML = "";
  const sections = skeleton && Array.isArray(skeleton.sections) ? skeleton.sections : [];
  for (const s of sections) {
    if (!s || typeof s.id !== "string") continue;
    const sid = window.mvKit.escapeAttr(s.id);
    const sTitle = window.mvKit.escapeHtml(s.title || "");
    const sType = window.mvKit.escapeAttr(s.type || "");
    let buttonsHTML = "";
    if (Array.isArray(s.deepDiveTopics)) {
      s.deepDiveTopics.forEach(function(topic, idx) {
        if (!topic) return;
        const label = window.mvKit.escapeHtml(topic.label || "");
        buttonsHTML += '<button class="dd-btn" data-section-id="' + sid + '" data-topic-index="' + idx + '">\u{1F93F} ' + label + "</button>";
      });
    }
    sectionsHTML += '<section data-section-id="' + sid + '" data-section-type="' + sType + '"><h2 class="section-title">' + sTitle + '</h2><div class="section-body" id="placeholder-' + sid + '"><div class="skeleton-loader"></div><div class="skeleton-loader skeleton-loader-short"></div><div class="skeleton-loader"></div></div>' + (buttonsHTML ? '<div class="dd-buttons">' + buttonsHTML + "</div>" : "") + "</section>";
  }
  const iframeScript = `
            (function() {
                'use strict';
                function postParent(type, payload) {
                    try { window.parent.postMessage({ type: type, payload: payload || {} }, '*'); }
                    catch (e) { /* no-op */ }
                }
                // Diagnostic: log IIFE entry, libs, errors. If only IIFE-START
                // arrives in diag log but no IIFE-END, something between threw.
                postParent('insightDebug', { where: 'iife', msg: 'IIFE-START readyState=' + document.readyState + ' libs={mermaid:' + (typeof mermaid) + ',Chart:' + (typeof Chart) + ',Prism:' + (typeof Prism) + '}' });
                window.addEventListener('error', function(ev) {
                    postParent('insightDebug', { where: 'iframe-window-error', msg: String(ev.message || ev.error || 'unknown') + ' @ ' + (ev.filename || '?') + ':' + (ev.lineno || 0) });
                });
                function escAttr(s) {   // mvkit-exempt: this code runs in the sandboxed Insight iframe, a document without mv-kit.js
                    if (s == null) return '';
                    return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
                }
                // Per-section pending lib-init flag (deferred until section streamed).
                function initSectionLib(sectionId) {
                    var sec = document.querySelector('section[data-section-id="' + escAttr(sectionId) + '"]');
                    if (!sec) {
                        postParent('insightDebug', { where: 'initSectionLib', msg: 'no section element for sid=' + sectionId });
                        return;
                    }
                    var type = sec.getAttribute('data-section-type') || '';
                    var bodyEl = sec.querySelector('.section-body');
                    var bodyLen = bodyEl ? (bodyEl.innerHTML || '').length : -1;
                    var preCount = sec.querySelectorAll('pre').length;
                    var canvasCount = sec.querySelectorAll('canvas').length;
                    var mermaidCount = sec.querySelectorAll('.mermaid, pre code.language-mermaid').length;
                    postParent('insightDebug', { where: 'initSectionLib', msg: 'sid=' + sectionId + ' type=' + type + ' bodyLen=' + bodyLen + ' pre=' + preCount + ' canvas=' + canvasCount + ' mermaid=' + mermaidCount + ' libs={mermaid:' + (typeof mermaid) + ',Chart:' + (typeof Chart) + ',Prism:' + (typeof Prism) + '}' });
                    try {
                        if (type === 'mermaidDiagram' && typeof mermaid !== 'undefined') {
                            // Accept several markup forms \u2014 LLM may emit any of:
                            //   <pre><code class="language-mermaid">SRC</code></pre>
                            //   <pre class="mermaid">SRC</pre>
                            //   <pre>graph TD...</pre>  (no class \u2014 fallback heuristic)
                            //   <div class="mermaid">SRC</div>
                            // Convert all to canonical <div class="mermaid">.
                            var nodesToConvert = sec.querySelectorAll(
                                'pre code.language-mermaid, pre.mermaid'
                            );
                            for (var i = 0; i < nodesToConvert.length; i++) {
                                var node = nodesToConvert[i];
                                var pre = (node.tagName === 'CODE') ? node.parentElement : node;
                                if (!pre) continue;
                                var src = (node.textContent || '').trim();
                                if (!src) continue;
                                // LLM sometimes emits literal "\\n" instead of newlines
                                // and "<br/>" inside node labels; normalise both.
                                var BS = String.fromCharCode(92);
                                var LF = String.fromCharCode(10);
                                src = src.split(BS + 'n').join(LF);
                                src = src.split(BS + BS).join(BS);
                                src = src.replace(/<br\\s*\\/>/gi, '<br>');
                                var div = document.createElement('div');
                                div.className = 'mermaid';
                                div.textContent = src;
                                pre.replaceWith(div);
                            }
                            // Heuristic fallback: any remaining <pre> whose first
                            // non-blank line starts with a known mermaid keyword.
                            var preList = sec.querySelectorAll('pre');
                            for (var pi = 0; pi < preList.length; pi++) {
                                var p = preList[pi];
                                var ptxt = (p.textContent || '').trim();
                                if (!ptxt) continue;
                                var firstLine = ptxt.split(/\\r?\\n/)[0].trim().toLowerCase();
                                if (/^(graph|flowchart|sequencediagram|classdiagram|statediagram|gantt|pie|gitgraph|journey|erdiagram|mindmap|timeline|quadrantchart)/.test(firstLine)) {
                                    var d = document.createElement('div');
                                    d.className = 'mermaid';
                                    d.textContent = ptxt;
                                    p.replaceWith(d);
                                }
                            }
                            try {
                                mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', flowchart: { htmlLabels: true },
                                                     theme: document.documentElement.getAttribute('data-theme') === 'dark' ? 'dark' : 'default' });
                                mermaid.run({ nodes: sec.querySelectorAll('.mermaid'), suppressErrors: true });
                            } catch (e) { /* per-block recover handled by mermaid */ }
                        } else if (type === 'chartJsChart' && typeof Chart !== 'undefined') {
                            // Phase 2 prompt uses data-chart; older code looked for
                            // data-chart-config. Accept both. LLM sometimes embeds
                            // JS function strings inside the JSON (callback fields)
                            // \u2014 strip those before JSON.parse so the rest renders.
                            var canvases = sec.querySelectorAll('canvas[data-chart], canvas[data-chart-config]');
                            for (var j = 0; j < canvases.length; j++) {
                                var cv = canvases[j];
                                if (cv.dataset && cv.dataset.chartRendered === '1') continue;
                                var cfgStr = cv.getAttribute('data-chart') || cv.getAttribute('data-chart-config') || '';
                                if (!cfgStr) continue;
                                var cleaned = cfgStr.replace(/"function"\\s*:\\s*"function[\\s\\S]*?"\\s*\\}/g, '"_stripped":true}');
                                try {
                                    var cfg = JSON.parse(cleaned);
                                    new Chart(cv, cfg);
                                    cv.dataset.chartRendered = '1';
                                } catch (e) {
                                    postParent('insightDebug', { where: 'chart-render', msg: 'sid=' + sectionId + ' parse/init failed: ' + String(e).substr(0, 200) });
                                }
                            }
                        }
                        if (typeof renderMathInElement === 'function') {
                            try { renderMathInElement(sec, { throwOnError: false }); } catch (e) {}
                        }
                        if (typeof Prism !== 'undefined') {
                            try { Prism.highlightAllUnder(sec); } catch (e) {}
                        }
                    } catch (e) { /* swallow lib init errors per section */ }
                }

                // Per-section buffer: HTML chunks streamed by Swift arrive
                // mid-tag (e.g. <canvas data-chart='{partial JSON ...). Calling
                // insertAdjacentHTML on each chunk re-parses fragmentary HTML
                // and the browser treats orphan attributes/text as text nodes
                // OUTSIDE the intended element \u2014 producing the "raw attribute
                // text" symptom users saw. Solution: append chunks to a string
                // buffer, flush via innerHTML once on section completion (the
                // initSectionLib trigger). Browser parses the FULL HTML at
                // once and elements like canvas end up correctly formed.
                var sectionBuffers = Object.create(null);
                var flushedSections = Object.create(null);
                function flushSectionBuffer(sectionId) {
                    var ph = document.getElementById('placeholder-' + sectionId);
                    if (!ph) return;
                    var html = sectionBuffers[sectionId] || '';
                    if (!html) return;
                    // innerHTML replaces all children \u2014 wipes skeleton loaders
                    // AND any prior partial parse. Browser parses the full
                    // string in one go.
                    try { ph.innerHTML = html; }
                    catch (e) { /* malformed \u2014 leave skeleton in place */ }
                    flushedSections[sectionId] = true;
                }

                window.addEventListener('message', function(ev) {
                    var data = ev.data;
                    if (!data || typeof data !== 'object') return;
                    if (typeof data.type !== 'string') return;
                    var p = data.payload || {};
                    if (data.type === 'updateInsightSection') {
                        var sid = String(p.sectionId || '');
                        if (!sid) return;
                        // Buffer the chunk; do NOT touch the DOM yet.
                        if (!sectionBuffers[sid]) sectionBuffers[sid] = '';
                        sectionBuffers[sid] += String(p.htmlChunk || '');
                    } else if (data.type === 'initSectionLib') {
                        var ssid = String(p.sectionId || '');
                        if (ssid) {
                            if (typeof p.html === 'string') sectionBuffers[ssid] = p.html;
                            flushSectionBuffer(ssid);
                        }
                        initSectionLib(ssid);
                    } else if (data.type === 'updateInsightProgress') {
                        // In-iframe progress banner \u2014 prominent feedback while
                        // generation is in flight. textContent ONLY (Decision 10).
                        var banner = document.getElementById('insight-progress-banner');
                        if (!banner) return;
                        var textEl = banner.querySelector('.insight-progress-text');
                        if (textEl && p.message != null) {
                            textEl.textContent = String(p.message);
                        }
                        if (p.phase === 'ready') {
                            banner.classList.add('insight-progress-done');
                            setTimeout(function() {
                                if (banner && banner.parentNode) {
                                    banner.parentNode.removeChild(banner);
                                }
                            }, 800);
                        }
                    } else if (data.type === 'setIframeStatus') {
                        // No iframe-side status surface yet; ignore.
                    }
                }, false);

                // \u{1F93F} deep-dive button click delegation.
                document.addEventListener('click', function(ev) {
                    var t = ev.target;
                    if (!t || !t.classList) return;
                    if (t.classList.contains('dd-btn')) {
                        var sid = t.getAttribute('data-section-id') || '';
                        var idx = parseInt(t.getAttribute('data-topic-index') || '0', 10);
                        postParent('insightDeepDiveClicked', { sectionId: sid, topicIndex: idx });
                    } else if (t.id === 'iframe-btn-save') {
                        postParent('insightRequestSave', {});
                    } else if (t.id === 'iframe-btn-up') {
                        postParent('insightRequestUp', {});
                    } else if (t.id === 'iframe-btn-custom-dd') {
                        var inp = document.getElementById('iframe-input-topic');
                        var topic = (inp && inp.value || '').trim();
                        if (!topic) return;
                        var langSel = document.getElementById('iframe-lang');
                        var lang = langSel ? langSel.value : 'auto';
                        postParent('insightRequestCustomDeepDive', { topic: topic, lang: lang });
                        if (inp) inp.value = '';
                    } else if (t.id === 'iframe-btn-explore-all') {
                        var sel = document.getElementById('iframe-explore-depth');
                        var depth = sel ? parseInt(sel.value || '1', 10) : 1;
                        if (!(depth >= 1 && depth <= 3)) depth = 1;
                        var langSel2 = document.getElementById('iframe-lang');
                        var lang2 = langSel2 ? langSel2.value : 'auto';
                        postParent('insightRequestExploreAll', { depth: depth, lang: lang2 });
                    } else if (t.hasAttribute && t.hasAttribute('data-retry-section')) {
                        var rsid = t.getAttribute('data-retry-section') || '';
                        if (rsid) postParent('insightRequestRetrySection', { sectionId: rsid });
                    }
                }, false);

                // Lightbox click-to-zoom for diagrams/charts/images. Builds
                // a fullscreen modal on first click, clones target into it,
                // provides +/-/reset/close + keyboard. Wrapped in try so any
                // closest()/clone failure can't kill iframeReady signal.
                try {
                    var lb = null, lbContent = null, lbZoom = 1, lbPanX = 0, lbPanY = 0;
                    var lbDragging = false, lbDragStartX = 0, lbDragStartY = 0, lbDragInitX = 0, lbDragInitY = 0;
                    function lbApplyTransform() {
                        if (lbContent) lbContent.style.transform = 'translate(' + lbPanX + 'px,' + lbPanY + 'px) scale(' + lbZoom + ')';
                    }
                    function lbSetZoom(z) {
                        lbZoom = Math.max(0.25, Math.min(8, z));
                        lbApplyTransform();
                        var pct = lb && lb.querySelector('.lb-pct');
                        if (pct) pct.textContent = Math.round(lbZoom * 100) + '%';
                    }
                    function lbResetPan() { lbPanX = 0; lbPanY = 0; lbApplyTransform(); }
                    function lbClose() { if (lb) lb.classList.remove('on'); if (lbContent) lbContent.innerHTML = ''; lbPanX = 0; lbPanY = 0; lbZoom = 1; }
                    function lbEnsure() {
                        if (lb) return;
                        lb = document.createElement('div'); lb.id = 'lb';
                        lb.innerHTML = '<div class="lb-stage"><div class="lb-content"></div></div>' +
                            '<div class="lb-bar">' +
                            '<button class="lb-out" title="Zoom out (-)">\u2212</button>' +
                            '<span class="lb-pct">100%</span>' +
                            '<button class="lb-in" title="Zoom in (+)">+</button>' +
                            '<button class="lb-reset" title="Reset (1)">1:1</button>' +
                            '<button class="lb-close" title="Close (Esc)">\u2715</button>' +
                            '</div>';
                        document.body.appendChild(lb);
                        lbContent = lb.querySelector('.lb-content');
                        lb.querySelector('.lb-in').addEventListener('click', function(e) { e.stopPropagation(); lbSetZoom(lbZoom * 1.25); });
                        lb.querySelector('.lb-out').addEventListener('click', function(e) { e.stopPropagation(); lbSetZoom(lbZoom / 1.25); });
                        lb.querySelector('.lb-reset').addEventListener('click', function(e) { e.stopPropagation(); lbResetPan(); lbSetZoom(1); });
                        lb.querySelector('.lb-close').addEventListener('click', function(e) { e.stopPropagation(); lbClose(); });
                        lb.addEventListener('click', function(ev) {
                            if (ev.target === lb || (ev.target.classList && ev.target.classList.contains('lb-stage'))) lbClose();
                        });
                        document.addEventListener('keydown', function(ev) {
                            if (!lb.classList.contains('on')) return;
                            if (ev.key === 'Escape') lbClose();
                            else if (ev.key === '+' || ev.key === '=') lbSetZoom(lbZoom * 1.25);
                            else if (ev.key === '-' || ev.key === '_') lbSetZoom(lbZoom / 1.25);
                            else if (ev.key === '0' || ev.key === '1') { lbResetPan(); lbSetZoom(1); }
                        });
                        lb.addEventListener('wheel', function(ev) {
                            if (ev.ctrlKey || ev.metaKey) { ev.preventDefault(); lbSetZoom(lbZoom * (ev.deltaY < 0 ? 1.1 : 0.9)); }
                        }, { passive: false });
                        // Drag-to-pan: mousedown anywhere on the content (or
                        // empty stage). Disable smooth-transition while dragging.
                        lbContent.addEventListener('mousedown', function(ev) {
                            if (ev.target.closest('.lb-bar')) return;
                            lbDragging = true;
                            lbDragStartX = ev.clientX; lbDragStartY = ev.clientY;
                            lbDragInitX = lbPanX; lbDragInitY = lbPanY;
                            lbContent.style.transition = 'none';
                            lbContent.style.cursor = 'grabbing';
                            ev.preventDefault();
                        });
                        document.addEventListener('mousemove', function(ev) {
                            if (!lbDragging) return;
                            lbPanX = lbDragInitX + (ev.clientX - lbDragStartX);
                            lbPanY = lbDragInitY + (ev.clientY - lbDragStartY);
                            lbApplyTransform();
                        });
                        document.addEventListener('mouseup', function() {
                            if (!lbDragging) return;
                            lbDragging = false;
                            if (lbContent) { lbContent.style.transition = ''; lbContent.style.cursor = ''; }
                        });
                    }
                    function lbOpen(el) {
                        lbEnsure();
                        lbContent.innerHTML = '';
                        var clone = null;
                        if (el.classList && el.classList.contains('mermaid')) {
                            var inner = el.querySelector('svg');
                            if (inner) el = inner;
                        }
                        if (el.tagName && el.tagName.toUpperCase() === 'CANVAS') {
                            try {
                                var img = document.createElement('img');
                                img.src = el.toDataURL('image/png');
                                img.style.width = el.width + 'px';
                                img.style.height = el.height + 'px';
                                clone = img;
                            } catch (_) { clone = el.cloneNode(true); }
                        } else if (el.tagName && el.tagName.toLowerCase() === 'svg') {
                            try {
                                var box = el.viewBox && el.viewBox.baseVal;
                                var w = (box && box.width) ? box.width : (el.getBoundingClientRect().width || 800);
                                var h = (box && box.height) ? box.height : (el.getBoundingClientRect().height || 600);
                                var holder = document.createElement('div');
                                holder.style.cssText = 'width:' + (w * 2) + 'px; height:' + (h * 2) + 'px;';
                                // A copy of the nodes already on the page: no markup is parsed again, so nothing new can enter (FU-25).
                                var ns = el.cloneNode(true);
                                ns.setAttribute('width', '100%'); ns.setAttribute('height', '100%'); ns.style.maxWidth = 'none'; ns.style.maxHeight = 'none';
                                holder.appendChild(ns);
                                clone = holder;
                            } catch (_) { clone = el.cloneNode(true); }
                        } else {
                            clone = el.cloneNode(true);
                        }
                        if (!clone) clone = el.cloneNode(true);
                        lbContent.appendChild(clone);
                        lbSetZoom(1);
                        lb.classList.add('on');
                    }
                    document.addEventListener('click', function(ev) {
                        var t = ev.target;
                        if (!t || typeof t.closest !== 'function') return;
                        var pick = t.closest('.mermaid, .section-body canvas, .section-body img');
                        if (!pick) return;
                        if (t.closest('.dd-btn, .iframe-footer, .lb-bar, #lb')) return;
                        ev.preventDefault(); ev.stopPropagation();
                        try { lbOpen(pick); } catch (e) { postParent('insightDebug', { where: 'lb-open', msg: String(e).substr(0, 200) }); }
                    }, false);
                } catch (e) { /* lightbox not critical */ }

                // Selection-driven custom deep-dive. Highlight any text in
                // the page \u2192 popup appears next to selection \u2192 click =
                // sends the selected text as a custom deep-dive topic
                // (same path as the footer \u{1F93F} Explore input).
                try {
                    var selPopup = document.createElement('div');
                    selPopup.id = 'sel-popup';
                    selPopup.innerHTML = '<span>\u{1F93F}</span><span>Deep dive on this</span>';
                    document.body.appendChild(selPopup);
                    var selText = '';
                    function hideSelPopup() { selPopup.classList.remove('on'); selText = ''; }
                    document.addEventListener('mouseup', function(ev) {
                        if (ev.target && ev.target.id === 'sel-popup') return;
                        if (ev.target && ev.target.closest && ev.target.closest('#sel-popup')) return;
                        // Defer one tick so getSelection reflects the final state.
                        setTimeout(function() {
                            var sel = window.getSelection();
                            var raw = sel ? String(sel.toString() || '').trim() : '';
                            // Skip very short / oversized selections.
                            if (raw.length < 3 || raw.length > 600) { hideSelPopup(); return; }
                            // Position popup just above the selection rect.
                            try {
                                var range = sel.getRangeAt(0);
                                var rect = range.getBoundingClientRect();
                                if (!rect || (rect.width === 0 && rect.height === 0)) { hideSelPopup(); return; }
                                var top = (rect.top + window.scrollY) - 36;
                                var left = (rect.left + window.scrollX) + Math.min(rect.width, 200) - 60;
                                if (top < 8) top = (rect.bottom + window.scrollY) + 8;
                                if (left < 8) left = 8;
                                selPopup.style.top = top + 'px';
                                selPopup.style.left = left + 'px';
                                selText = raw;
                                selPopup.classList.add('on');
                            } catch (e) { hideSelPopup(); }
                        }, 0);
                    });
                    selPopup.addEventListener('click', function(ev) {
                        ev.stopPropagation();
                        if (!selText) return;
                        postParent('insightRequestCustomDeepDive', { topic: selText });
                        hideSelPopup();
                        try { window.getSelection().removeAllRanges(); } catch (_) {}
                    });
                    document.addEventListener('mousedown', function(ev) {
                        if (ev.target && ev.target.closest && ev.target.closest('#sel-popup')) return;
                        hideSelPopup();
                    });
                } catch (e) { /* selection popup not critical */ }

                postParent('insightDebug', { where: 'iife', msg: 'IIFE-END about to signal ready, readyState=' + document.readyState });
                // Signal readiness once DOM is parsed.
                if (document.readyState === 'loading') {
                    document.addEventListener('DOMContentLoaded', function() { postParent('insightIframeReady', {}); });
                } else {
                    postParent('insightIframeReady', {});
                }
            })();
            `;
  const uiScale = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--ui-scale")) || 1;
  const inlineCSS = `
            :root { --ui-scale: ${uiScale}; }
            html, body { margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif; background: #fff; color: #1e1e1e; }
            body { padding: 16px 24px; padding-top: 0; }
            .insight-progress-banner {
                position: sticky;
                top: 0;
                left: 0;
                right: 0;
                z-index: 100;
                margin: 0 -24px 16px;
                background: linear-gradient(90deg, rgba(74,158,255,0.18), rgba(74,158,255,0.06));
                border-bottom: 1px solid rgba(74,158,255,0.35);
                padding: 14px 18px;
                display: flex;
                align-items: center;
                gap: 12px;
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
                font-size: calc(14px * var(--ui-scale, 1));
                color: #2563eb;
                transition: opacity 0.6s ease-out;
            }
            .insight-progress-icon {
                font-size: calc(18px * var(--ui-scale, 1));
                display: inline-block;
                animation: insight-spin 1.5s linear infinite;
                transform-origin: 50% 50%;
            }
            .insight-progress-text { flex: 1; }
            @keyframes insight-spin {
                from { transform: rotate(0deg); }
                to { transform: rotate(360deg); }
            }
            .insight-progress-banner.insight-progress-done {
                opacity: 0;
                pointer-events: none;
            }
            .insight-progress-banner.insight-progress-done .insight-progress-icon {
                animation: none;
            }
            .insight-doc-title { font-size: calc(20px * var(--ui-scale, 1)); font-weight: 700; margin: 16px 0 16px; }
            section { margin-bottom: 28px; padding-bottom: 20px; border-bottom: 1px solid #e0e0e0; }
            section:last-of-type { border-bottom: none; }
            .section-title { font-size: calc(16px * var(--ui-scale, 1)); font-weight: 600; margin: 0 0 8px; color: #2a2a2a; }
            .section-body { font-size: calc(14px * var(--ui-scale, 1)); line-height: 1.6; }
            .section-body img { max-width: 100%; height: auto; }
            /* Hero: compact. */
            section[data-section-type="hero"] { margin-bottom: 18px; padding-bottom: 14px; }
            section[data-section-type="hero"] .section-title { display: none; }
            section[data-section-type="hero"] .section-body h1 { font-size: calc(22px * var(--ui-scale, 1)); line-height: 1.2; margin: 0 0 6px; color: #1e1e1e; font-weight: 700; }
            section[data-section-type="hero"] .section-body h1 + p { font-size: calc(14px * var(--ui-scale, 1)); line-height: 1.5; margin: 0 0 4px; color: #4a4a4a; }
            section[data-section-type="hero"] .section-body p { margin: 4px 0; }
            section[data-section-type="hero"] .section-body { font-size: calc(13px * var(--ui-scale, 1)); }
            /* Mermaid: cap diagram height; the lightbox shows it full-size. */
            .mermaid { max-height: 520px; overflow: hidden; cursor: zoom-in; }
            .mermaid svg { max-width: 100%; height: auto; max-height: 520px; display: block; margin: 0 auto; }
            /* Chart: cap height + overflow hidden. */
            section[data-section-type="chartJsChart"] .section-body {
                position: relative; height: 360px; max-height: 50vh; overflow: hidden; cursor: zoom-in;
            }
            section[data-section-type="chartJsChart"] canvas {
                max-height: 360px !important; max-width: 100% !important; display: block;
            }
            /* Tables: zebra rows + hover. */
            .section-body table { width: 100%; border-collapse: collapse; margin: 6px 0 12px; font-size: calc(13px * var(--ui-scale, 1)); }
            .section-body th, .section-body td { padding: 6px 10px; border: 1px solid #e0e0e0; text-align: left; vertical-align: top; }
            .section-body th { background: #f5f7fb; font-weight: 600; color: #1e1e1e; }
            .section-body tbody tr:nth-child(odd) td { background: #fafafa; }
            .section-body tbody tr:hover td { background: #f0f4ff; }
            /* Cards grid + Callouts + Timeline. */
            .cards-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 12px; }
            .cards-grid .card { background: #f8f9fb; border: 1px solid #e0e0e0; border-radius: 6px; padding: 10px 12px; }
            .cards-grid .card h3 { margin: 0 0 6px; font-size: calc(13px * var(--ui-scale, 1)); font-weight: 600; }
            .cards-grid .card p { margin: 4px 0; font-size: calc(12px * var(--ui-scale, 1)); line-height: 1.45; }
            .callout { padding: 10px 14px; border-left: 4px solid #6b7280; background: #f5f7fb; margin: 8px 0; border-radius: 4px; }
            .callout.callout-info { border-color: #3b82f6; background: #eff6ff; }
            .callout.callout-warn { border-color: #f59e0b; background: #fffbeb; }
            .callout.callout-danger { border-color: #ef4444; background: #fef2f2; }
            .callout.callout-tip { border-color: #10b981; background: #ecfdf5; }
            .timeline { list-style: none; padding: 0; margin: 8px 0; border-left: 2px solid #d4d4d4; }
            .timeline li { position: relative; padding: 4px 0 8px 16px; }
            .timeline li::before { content: ''; position: absolute; left: -6px; top: 8px; width: 10px; height: 10px; background: #569cd6; border-radius: 50%; }
            .timeline time { display: inline-block; font-weight: 600; color: #1e1e1e; margin-right: 6px; }
            /* Lightbox modal for click-to-zoom on diagrams/charts/images. */
            #lb {
                position: fixed; inset: 0; z-index: 10000;
                background: rgba(0,0,0,0.88);
                display: none; align-items: center; justify-content: center;
                padding: 32px; box-sizing: border-box;
            }
            #lb.on { display: flex; }
            #lb .lb-stage { position: relative; width: 100%; height: 100%; overflow: auto; display: flex; align-items: center; justify-content: center; }
            #lb .lb-content { transform-origin: center center; transition: transform 0.18s ease; background: #fff; padding: 16px; border-radius: 6px; cursor: grab; user-select: none; }
            #lb .lb-content svg, #lb .lb-content img, #lb .lb-content canvas { display: block; max-width: none; max-height: none; }
            #lb .lb-bar { position: absolute; top: 16px; right: 16px; display: flex; gap: 6px; background: #fff; padding: 6px 10px; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.3); }
            #lb .lb-bar button { background: #f4f4f4; color: #1e1e1e; border: 1px solid #d0d0d0; border-radius: 4px; padding: 6px 12px; font-size: calc(14px * var(--ui-scale, 1)); cursor: pointer; font-family: inherit; min-width: 36px; }
            #lb .lb-bar button:hover { background: #2563eb; color: #fff; border-color: #2563eb; }
            #lb .lb-bar .lb-pct { display: inline-flex; align-items: center; padding: 0 6px; font-size: calc(13px * var(--ui-scale, 1)); color: #666; min-width: 50px; justify-content: center; }
            /* Selection popup \u2014 appears on text selection inside the iframe.
               Click \u2192 custom deep-dive on the selected text. */
            #sel-popup {
                position: absolute; z-index: 9999;
                display: none;
                background: #1e1e1e; color: #fff;
                border-radius: 6px; padding: 6px 10px;
                box-shadow: 0 4px 12px rgba(0,0,0,0.3);
                font-size: calc(12px * var(--ui-scale, 1)); cursor: pointer;
                user-select: none; white-space: nowrap;
            }
            #sel-popup.on { display: inline-flex; align-items: center; gap: 6px; }
            #sel-popup:hover { background: #2563eb; }
            .skeleton-loader {
                height: 12px; margin: 6px 0; border-radius: 4px;
                background: linear-gradient(90deg, #e8e8e8 25%, #f4f4f4 50%, #e8e8e8 75%);
                background-size: 200% 100%;
                animation: skeleton-pulse 1.4s ease-in-out infinite;
            }
            .skeleton-loader-short { width: 60%; }
            @keyframes skeleton-pulse {
                0% { background-position: 200% 0; }
                100% { background-position: -200% 0; }
            }
            .dd-buttons { margin-top: 10px; display: flex; flex-wrap: wrap; gap: 6px; }
            .dd-btn {
                background: #f4f4f4; color: #1e1e1e; border: 1px solid #d0d0d0; border-radius: 4px;
                padding: 4px 10px; font-size: calc(12px * var(--ui-scale, 1)); cursor: pointer; font-family: inherit;
            }
            .dd-btn:hover { background: #e8e8e8; border-color: #909090; }
            .iframe-footer {
                position: sticky; bottom: 0; left: 0; right: 0;
                background: #fafafa; border-top: 1px solid #e0e0e0;
                padding: 8px 0; margin-top: 24px; display: flex; gap: 8px;
            }
            .iframe-footer .spacer { flex: 1; }
            .iframe-footer input#iframe-input-topic {
                flex: 2; min-width: 220px; max-width: 520px;
                padding: 6px 10px; font-size: calc(12px * var(--ui-scale, 1)); font-family: inherit;
                border: 1px solid #d0d0d0; border-radius: 4px; background: #fff; color: #1e1e1e;
            }
            .iframe-footer input#iframe-input-topic:focus { outline: none; border-color: #2563eb; }
            .iframe-footer select#iframe-explore-depth { padding: 5px 6px; font-size: calc(11px * var(--ui-scale, 1)); border: 1px solid #d0d0d0; border-radius: 4px; background: #fff; color: #1e1e1e; cursor: pointer; }
            .iframe-footer button {
                background: #f4f4f4; color: #1e1e1e; border: 1px solid #d0d0d0; border-radius: 4px;
                padding: 5px 12px; font-size: calc(11px * var(--ui-scale, 1)); cursor: pointer; font-family: inherit;
            }
            .iframe-footer button:hover { background: #2563eb; color: #fff; border-color: #2563eb; }
            pre { background: #f6f8fa; padding: 10px; border-radius: 4px; overflow-x: auto; font-size: calc(12px * var(--ui-scale, 1)); }
            code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
            /* The app's dark theme: the page follows the parent's data-theme (set at build and on toggle). */
            html[data-theme="dark"], html[data-theme="dark"] body { background: #1e1e1e; color: #d4d4d4; }
            html[data-theme="dark"] h1, html[data-theme="dark"] h2, html[data-theme="dark"] h3, html[data-theme="dark"] h4, html[data-theme="dark"] th, html[data-theme="dark"] .crumb-active, html[data-theme="dark"] .timeline time, html[data-theme="dark"] section.insight-section h2,
            html[data-theme="dark"] section[data-section-type="hero"] .section-body h1, html[data-theme="dark"] .cards-grid .card h3, html[data-theme="dark"] .cards-grid > article h3 { color: #d4d4d4; }
            html[data-theme="dark"] section[data-section-type="hero"] .section-body h1 + p { color: #a0a0a0; }
            html[data-theme="dark"] a, html[data-theme="dark"] .crumb { color: #4a9eff; }
            html[data-theme="dark"] .crumb:hover { background: #2d2d30; }
            html[data-theme="dark"] .crumb-sep { color: #808080; }
            html[data-theme="dark"] header.insight-breadcrumbs, html[data-theme="dark"] section.insight-section { border-color: #3c3c3c; }
            html[data-theme="dark"] .section-body th, html[data-theme="dark"] .section-body td { border-color: #3c3c3c; }
            html[data-theme="dark"] .section-body th { background: #2d2d30; }
            html[data-theme="dark"] .section-body tbody tr:nth-child(odd) td { background: #232323; }
            html[data-theme="dark"] .cards-grid .card, html[data-theme="dark"] .cards-grid > article { background: #252526; border-color: #3c3c3c; }
            html[data-theme="dark"] .cards-grid .card .meta, html[data-theme="dark"] .cards-grid > article .meta { color: #9a9a9a; }
            html[data-theme="dark"] .callout { background: #252526; border-left-color: #6b7280; }
            html[data-theme="dark"] .callout.callout-info { background: #1b2838; }
            html[data-theme="dark"] .callout.callout-warn { background: #2d2614; }
            html[data-theme="dark"] .callout.callout-danger { background: #2e1a1a; }
            html[data-theme="dark"] .callout.callout-tip { background: #16281f; }
            html[data-theme="dark"] .timeline { border-left-color: #3c3c3c; }
            html[data-theme="dark"] .deep-dive, html[data-theme="dark"] .dd-btn, html[data-theme="dark"] .iframe-footer button, html[data-theme="dark"] #lb .lb-bar button { background: #2d2d30; color: #d4d4d4; border-color: #3c3c3c; }
            html[data-theme="dark"] .deep-dive:hover, html[data-theme="dark"] .dd-btn:hover { background: #3c3c3c; border-color: #5a5a5a; }
            html[data-theme="dark"] .iframe-footer { background: #252526; border-top-color: #3c3c3c; }
            html[data-theme="dark"] .iframe-footer input#iframe-input-topic, html[data-theme="dark"] .iframe-footer select { background: #1e1e1e; color: #d4d4d4; border-color: #3c3c3c; }
            html[data-theme="dark"] pre { background: #252526; color: #d4d4d4; }
            html[data-theme="dark"] .inferred { color: #e2a93b; border-bottom-color: #e2a93b; }
            html[data-theme="dark"] .skeleton-loader { background: linear-gradient(90deg, #2d2d30 25%, #3c3c3c 50%, #2d2d30 75%); background-size: 200% 100%; }
            html[data-theme="dark"] #lb .lb-content, html[data-theme="dark"] #lb .lb-bar { background: #252526; }
            html[data-theme="dark"] #lb .lb-bar .lb-pct { color: #a0a0a0; }
            html[data-theme="dark"] .insight-progress-banner { color: #4a9eff; }
            `;
  const theme = document.documentElement.getAttribute("data-theme") === "dark" ? "dark" : "light";
  return '<!DOCTYPE html><html data-theme="' + theme + '"><head><meta http-equiv="Content-Security-Policy" content="' + window.mvKit.escapeAttr(csp) + '"><meta charset="UTF-8"><title>' + title + "</title><style>" + inlineCSS + "</style>" + katexStyleBlock + libScripts + '</head><body><div id="insight-progress-banner" class="insight-progress-banner"><div class="insight-progress-icon">\u2699</div><div class="insight-progress-text">Initializing\u2026</div></div><h1 class="insight-doc-title">' + title + "</h1>" + sectionsHTML + `<div class="iframe-footer"><button id="iframe-btn-up" title="Up to parent">\u2191 Up</button><select id="iframe-explore-depth" title="Recursion depth for Explore-all"><option value="1" selected>depth 1</option><option value="2">depth 2</option><option value="3">depth 3</option></select><button id="iframe-btn-explore-all" title="Generate deep-dive pages for EVERY \u{1F93F} topic on this page. Depth>1 means recursively expand each child's topics too \u2014 cost grows fast.">\u{1F93F}\xD7N Explore all</button><input id="iframe-input-topic" placeholder="Custom deep-dive topic (e.g. 'Compare auth approaches across the project')\u2026" /><button id="iframe-btn-custom-dd" title="Generate a deep-dive page on this custom topic using all source files">\u{1F93F} Explore</button><div class="spacer"></div><button id="iframe-btn-save" title="Export the whole insight tree as a self-contained ZIP website">\u{1F4E6} Export ZIP</button></div><script` + nonceAttr + ">" + iframeScript + "<\/script></body></html>";
}
;
function switchToInsightView() {
  state.mode = "insight";
  if (DOM.editorPane) DOM.editorPane.style.display = "none";
  if (DOM.previewPane) DOM.previewPane.style.display = "none";
  if (DOM.insightContainer) {
    DOM.insightContainer.classList.add("visible");
    DOM.insightContainer.style.display = "flex";
  }
  const wt = document.getElementById("wysiwyg-toolbar");
  if (wt) wt.style.display = "none";
  if (DOM.statusMode) DOM.statusMode.textContent = "Insight";
}
function showInsightLoadingOverlay(message) {
  if (!DOM.insightContainer) return;
  switchToInsightView();
  if (state.insightIframe) state.insightIframe.style.display = "none";
  else if (DOM.insightIframe) DOM.insightIframe.style.display = "none";
  let overlay = document.getElementById("insight-loading-overlay");
  if (!overlay) {
    overlay = document.createElement("div");
    overlay.id = "insight-loading-overlay";
    overlay.style.cssText = "position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:18px;font-family:-apple-system,system-ui,sans-serif;background:var(--bg-primary,#1e1e1e);color:var(--text-primary,#d4d4d4);padding:40px;text-align:center;";
    const spinner = document.createElement("div");
    spinner.style.cssText = "width:48px;height:48px;border:4px solid #3c3c3c;border-top-color:#569cd6;border-radius:50%;animation:insight-spin 1s linear infinite;";
    overlay.appendChild(spinner);
    const title = document.createElement("div");
    title.id = "insight-loading-title";
    title.style.cssText = "font-size:calc(18px * var(--ui-scale, 1));font-weight:600;";
    title.textContent = "Generating insight\u2026";
    overlay.appendChild(title);
    const sub = document.createElement("div");
    sub.id = "insight-loading-sub";
    sub.style.cssText = "font-size:calc(13px * var(--ui-scale, 1));color:var(--text-secondary,#808080);max-width:480px;line-height:1.5;";
    sub.textContent = message || "Phase 1: analysing files (typically 30\u201360 s)\u2026";
    overlay.appendChild(sub);
    if (!document.getElementById("insight-loading-style")) {
      const st = document.createElement("style");
      st.id = "insight-loading-style";
      st.textContent = "@keyframes insight-spin { to { transform: rotate(360deg); } }";
      document.head.appendChild(st);
    }
    if (DOM.insightContainer && getComputedStyle(DOM.insightContainer).position === "static") {
      DOM.insightContainer.style.position = "relative";
    }
    DOM.insightContainer.appendChild(overlay);
  } else {
    const sub = document.getElementById("insight-loading-sub");
    if (sub && message != null) sub.textContent = String(message);
  }
}
function hideInsightLoadingOverlay() {
  const overlay = document.getElementById("insight-loading-overlay");
  if (overlay && overlay.parentNode) overlay.parentNode.removeChild(overlay);
  if (state.insightIframe) state.insightIframe.style.display = "";
  else if (DOM.insightIframe) DOM.insightIframe.style.display = "";
}
function leaveInsightView() {
  if (DOM.insightContainer) {
    DOM.insightContainer.classList.remove("visible");
    DOM.insightContainer.style.display = "none";
  }
}
function renderInsightBreadcrumbs(crumbs) {
  const bar = DOM.insightBreadcrumbs;
  if (!bar) return;
  while (bar.firstChild) bar.removeChild(bar.firstChild);
  const arr = Array.isArray(crumbs) ? crumbs : [];
  const upBtn = document.createElement("button");
  upBtn.className = "insight-up-btn";
  upBtn.title = arr.length > 1 ? "Back to parent" : "Already at root";
  upBtn.textContent = "\u2191 Up";
  upBtn.disabled = arr.length <= 1;
  if (arr.length > 1) {
    upBtn.addEventListener("click", function() {
      sendToSwift("insightRequestUp", { sessionId: state.insightSessionId });
    });
  }
  bar.appendChild(upBtn);
  const regenBtn = document.createElement("button");
  regenBtn.className = "insight-up-btn";
  regenBtn.title = "Discard cached insight and regenerate from scratch (uses LLM tokens)";
  regenBtn.textContent = "\u27F3 Regenerate";
  regenBtn.addEventListener("click", function() {
    sendToSwift("insightRequestRegenerate", { sessionId: state.insightSessionId });
  });
  bar.appendChild(regenBtn);
  arr.forEach(function(crumb, idx) {
    const isLast = idx === arr.length - 1;
    const item = document.createElement("span");
    item.className = "insight-breadcrumb-item" + (isLast ? " current" : "");
    item.textContent = crumb && crumb.title ? String(crumb.title) : "(untitled)";
    if (!isLast) {
      const nodeId = crumb && crumb.nodeId ? String(crumb.nodeId) : null;
      item.addEventListener("click", function() {
        sendToSwift("insightBreadcrumbClicked", {
          sessionId: state.insightSessionId,
          nodeId
        });
      });
    }
    bar.appendChild(item);
    if (!isLast) {
      const sep = document.createElement("span");
      sep.className = "insight-breadcrumb-sep";
      sep.textContent = "\u203A";
      bar.appendChild(sep);
    }
  });
}
function setStatusBar(message, phase, isError) {
  const bar = DOM.insightStatusBar;
  if (!bar) return;
  const next = message == null ? "" : String(message);
  const changed = bar.textContent !== next;
  bar.textContent = next;
  bar.classList.remove("phase-1", "phase-2", "ready", "error");
  if (isError) bar.classList.add("error");
  else if (phase === "phase-1" || phase === "phase-2" || phase === "ready") bar.classList.add(phase);
  if (changed && next !== "") {
    bar.classList.remove("insight-status-pulse");
    void bar.offsetWidth;
    bar.classList.add("insight-status-pulse");
  }
}
function handleIframeLoadTimeout(sessionId) {
  if (!state.insightIframe) return;
  if (state.insightIframeReady) return;
  if (state.insightSessionId !== sessionId) return;
  console.warn("[insight] iframe failed to load within 10s for session", sessionId);
  setStatusBar("iframe failed to load within 10s", null, true);
  try {
    state.insightIframe.removeAttribute("srcdoc");
  } catch (e) {
  }
}
function startIframeLoadTimer(sessionId) {
  if (state.insightLoadTimer) {
    clearTimeout(state.insightLoadTimer);
    state.insightLoadTimer = null;
  }
  state.insightLoadTimer = setTimeout(function() {
    handleIframeLoadTimeout(sessionId);
  }, 1e4);
}
function clearIframeLoadTimer() {
  if (state.insightLoadTimer) {
    clearTimeout(state.insightLoadTimer);
    state.insightLoadTimer = null;
  }
}
;
function stripCDNTags(html) {
  if (typeof html !== "string") return "";
  let out = html;
  out = out.replace(/^\s*```(?:html|HTML)?\s*\n?/, "");
  out = out.replace(/\n?```\s*$/, "");
  out = out.replace(/^\s*```(?:html|HTML)?\s*$/gm, "");
  return window.mvKit.sanitizeHtml(out, "insight");
}
window.loadInsightSkeleton = async function(skeletonOrJSON, sessionId, nodeId, breadcrumbsArg) {
  let skeleton = skeletonOrJSON;
  if (typeof skeleton === "string") {
    try {
      skeleton = JSON.parse(skeleton);
    } catch (e) {
      console.warn("[insight] loadInsightSkeleton: invalid JSON");
      return;
    }
  }
  if (!skeleton || typeof skeleton !== "object" || !Array.isArray(skeleton.sections)) {
    console.warn("[insight] loadInsightSkeleton: missing sections array");
    return;
  }
  const sid = sessionId != null ? String(sessionId) : null;
  const nid = nodeId != null ? String(nodeId) : null;
  if (Array.isArray(breadcrumbsArg) && breadcrumbsArg.length > 0) {
    skeleton.breadcrumbs = breadcrumbsArg;
  }
  try {
    sendToSwift("jsError", { where: "parent-loadInsightSkeleton-syncInit", message: "sid=" + sid + " previous_sid=" + state.insightSessionId + " previous_pending_size=" + (state.insightPendingChunks ? state.insightPendingChunks.size : "NULL"), source: "", lineno: 0, colno: 0, stack: "" });
  } catch (_) {
  }
  state.insightSessionId = sid;
  state.insightCurrentNodeId = nid;
  state.insightSkeleton = skeleton;
  state.insightIframeReady = false;
  state.insightPendingChunks = /* @__PURE__ */ new Map();
  state.insightSectionRawBuffers = /* @__PURE__ */ new Map();
  const newLibs = computeRequiredLibs(skeleton);
  const libSourcePromises = [];
  for (const libName of newLibs) {
    libSourcePromises.push(ensureLibSource(libName));
  }
  await Promise.all(libSourcePromises);
  let katexCSSInline = "";
  if (newLibs.has("katex")) {
    katexCSSInline = await ensureKatexCSSInline();
  }
  state.insightSectionLibsNeeded = newLibs;
  switchToInsightView();
  const crumbs = Array.isArray(skeleton.breadcrumbs) ? skeleton.breadcrumbs : [{ nodeId: nid, title: skeleton.title || "" }];
  renderInsightBreadcrumbs(crumbs);
  setStatusBar("Loading\u2026", "phase-1", false);
  const srcdoc = await buildInsightSrcdoc(skeleton, katexCSSInline);
  if (!state.insightIframe || !document.body.contains(state.insightIframe)) {
    state.insightIframe = document.getElementById("insight-iframe");
    DOM.insightIframe = state.insightIframe;
  }
  if (!state.insightIframe) {
    console.warn("[insight] iframe element missing");
    return;
  }
  state.insightIframe.setAttribute("sandbox", "allow-scripts");
  state.insightIframe.srcdoc = srcdoc;
  try {
    sendToSwift("jsError", {
      where: "parent-loadInsightSkeleton-srcdocSet",
      message: "srcdocLen=" + srcdoc.length + " iframeInDOM=" + document.body.contains(state.insightIframe) + " iframeDisplay=" + (state.insightIframe.style.display || "default") + " containerVisible=" + (DOM.insightContainer && DOM.insightContainer.classList.contains("visible")),
      source: "",
      lineno: 0,
      colno: 0,
      stack: ""
    });
  } catch (_) {
  }
  if (typeof hideInsightLoadingOverlay === "function") hideInsightLoadingOverlay();
  startIframeLoadTimer(sid);
};
window.updateInsightSection = function(sessionId, sectionId, htmlChunk) {
  const sid = sessionId != null ? String(sessionId) : null;
  if (sid !== state.insightSessionId) {
    try {
      sendToSwift("jsError", {
        where: "parent-updateInsightSection-stale",
        message: "incoming sid=" + sid + " state.sid=" + state.insightSessionId + " secId=" + sectionId,
        source: "",
        lineno: 0,
        colno: 0,
        stack: ""
      });
    } catch (_) {
    }
    return;
  }
  const secId = String(sectionId || "");
  if (!secId) return;
  const skel = state.insightSkeleton;
  if (!skel || !Array.isArray(skel.sections) || !skel.sections.find(function(s) {
    return s && s.id === secId;
  })) {
    console.warn("[insight] updateInsightSection: unknown sectionId", secId);
    return;
  }
  const rawChunk = typeof htmlChunk === "string" ? htmlChunk : "";
  if (!state.insightSectionRawBuffers) state.insightSectionRawBuffers = /* @__PURE__ */ new Map();
  state.insightSectionRawBuffers.set(secId, (state.insightSectionRawBuffers.get(secId) || "") + rawChunk);
  const stripped = stripCDNTags(rawChunk);
  if (!state.insightIframeReady || !state.insightIframe) {
    if (!state.insightPendingChunks.has(secId)) state.insightPendingChunks.set(secId, []);
    state.insightPendingChunks.get(secId).push(stripped);
    try {
      sendToSwift("jsError", { where: "parent-updateInsightSection-buffered", message: "secId=" + secId + " size_after=" + state.insightPendingChunks.size + " iframeReady=" + state.insightIframeReady, source: "", lineno: 0, colno: 0, stack: "" });
    } catch (_) {
    }
    return;
  }
  try {
    sendToSwift("jsError", { where: "parent-updateInsightSection-direct", message: "secId=" + secId + " iframeReady=" + state.insightIframeReady, source: "", lineno: 0, colno: 0, stack: "" });
  } catch (_) {
  }
  try {
    state.insightIframe.contentWindow.postMessage({
      type: "updateInsightSection",
      payload: { sessionId: sid, sectionId: secId, htmlChunk: stripped }
    }, "*");
  } catch (e) {
    console.warn("[insight] failed to post updateInsightSection:", e);
  }
  if (!state.insightSectionInitTimers) state.insightSectionInitTimers = /* @__PURE__ */ new Map();
  const prevTimer = state.insightSectionInitTimers.get(secId);
  if (prevTimer) clearTimeout(prevTimer);
  const t = setTimeout(function() {
    state.insightSectionInitTimers.delete(secId);
    if (!state.insightIframe || !state.insightIframe.contentWindow) return;
    const fullRaw = state.insightSectionRawBuffers && state.insightSectionRawBuffers.get(secId) || "";
    const cleanHTML = stripCDNTags(fullRaw);
    try {
      state.insightIframe.contentWindow.postMessage({
        type: "initSectionLib",
        payload: { sectionId: secId, html: cleanHTML }
      }, "*");
    } catch (e) {
    }
  }, 100);
  state.insightSectionInitTimers.set(secId, t);
};
window.setInsightError = function(sessionId, message, retryable) {
  const sid = sessionId != null ? String(sessionId) : null;
  if (sid !== null && state.insightSessionId !== null && sid !== state.insightSessionId) {
    return;
  }
  setStatusBar(message || "Error", null, true);
  if (retryable) {
    const bar = DOM.insightStatusBar;
    if (bar && message) bar.textContent = String(message) + " \u2014 retry by re-invoking action";
  }
};
window.setInsightStatus = function(sessionId, message, phase) {
  const sid = sessionId != null ? String(sessionId) : null;
  if (sid !== null && state.insightSessionId !== null && sid !== state.insightSessionId) {
    return;
  }
  if (sid !== null && state.insightSessionId === null) {
    state.insightSessionId = sid;
  }
  const isPhase1Active = typeof message === "string" && /\bphase 1\b.*\banalyz/i.test(message);
  if (isPhase1Active && typeof showInsightLoadingOverlay === "function") {
    showInsightLoadingOverlay(message);
  }
  state.insightLastStatus = { message, phase };
  setStatusBar(message, phase, false);
  try {
    const iframe = state.insightIframe || DOM.insightContainer && DOM.insightContainer.querySelector("iframe");
    if (iframe && iframe.contentWindow) {
      iframe.contentWindow.postMessage({
        type: "updateInsightProgress",
        payload: { message: message == null ? "" : String(message), phase: phase || "" }
      }, "*");
    }
  } catch (e) {
  }
};
window.releaseInsightBlobs = function() {
  state.insightLibBytes.clear();
  state.insightSectionLibsNeeded = /* @__PURE__ */ new Set();
};
const INSIGHT_ALLOWED_TYPES = /* @__PURE__ */ new Set([
  "insightIframeReady",
  "insightDeepDiveClicked",
  "insightBreadcrumbClicked",
  "insightRequestSave",
  "insightRequestUp",
  "insightRequestRegenerate",
  "insightRequestCustomDeepDive",
  "insightRequestExploreAll",
  "insightRequestRetrySection",
  "insightDebug"
  // diagnostic — forwarded to Swift jsError, no business behavior
]);
const UUID_REGEX = /^[0-9A-F-]{36}$/i;
function isPlainObject(v) {
  return v != null && typeof v === "object" && !Array.isArray(v);
}
window.addEventListener("message", function(ev) {
  try {
    sendToSwift("jsError", {
      where: "parent-onmessage-raw",
      message: "origin=" + JSON.stringify(ev.origin) + " typeof_data=" + typeof ev.data + " data_type=" + (ev.data && ev.data.type) + " has_iframe=" + !!state.insightIframe + " src_matches=" + (state.insightIframe && ev.source === state.insightIframe.contentWindow),
      source: "",
      lineno: 0,
      colno: 0,
      stack: ""
    });
  } catch (_) {
  }
  if (!state.insightIframe || ev.source !== state.insightIframe.contentWindow) {
    return;
  }
  const allowedOrigin = ev.origin === "null" || ev.origin === "" || typeof ev.origin === "string" && ev.origin.indexOf("file://") === 0;
  if (!allowedOrigin) {
    console.warn("[insight] rejected postMessage from unexpected origin:", ev.origin);
    return;
  }
  const data = ev.data;
  if (!isPlainObject(data) || typeof data.type !== "string") {
    console.warn("[insight] rejected malformed postMessage");
    return;
  }
  if (!INSIGHT_ALLOWED_TYPES.has(data.type)) {
    console.warn("[insight] rejected disallowed type:", data.type);
    return;
  }
  const payload = isPlainObject(data.payload) ? data.payload : {};
  switch (data.type) {
    case "insightIframeReady": {
      state.insightIframeReady = true;
      clearIframeLoadTimer();
      try {
        if (state.insightLastStatus && state.insightIframe && state.insightIframe.contentWindow) {
          state.insightIframe.contentWindow.postMessage({
            type: "updateInsightProgress",
            payload: { message: state.insightLastStatus.message || "", phase: state.insightLastStatus.phase || "" }
          }, "*");
        }
      } catch (_) {
      }
      try {
        sendToSwift("jsError", {
          where: "parent-iframeReady-flush",
          message: "pendingChunks.size=" + (state.insightPendingChunks ? state.insightPendingChunks.size : "NULL"),
          source: "",
          lineno: 0,
          colno: 0,
          stack: ""
        });
      } catch (_) {
      }
      if (state.insightPendingChunks.size > 0) {
        const flushedSectionIds = /* @__PURE__ */ new Set();
        for (const [secId2, chunks] of state.insightPendingChunks.entries()) {
          for (const chunk of chunks) {
            try {
              state.insightIframe.contentWindow.postMessage({
                type: "updateInsightSection",
                payload: { sessionId: state.insightSessionId, sectionId: secId2, htmlChunk: chunk }
              }, "*");
            } catch (e) {
            }
          }
          flushedSectionIds.add(secId2);
        }
        state.insightPendingChunks.clear();
        for (const secId2 of flushedSectionIds) {
          const fullRaw = state.insightSectionRawBuffers && state.insightSectionRawBuffers.get(secId2) || "";
          const cleanHTML = stripCDNTags(fullRaw);
          try {
            state.insightIframe.contentWindow.postMessage({
              type: "initSectionLib",
              payload: { sectionId: secId2, html: cleanHTML }
            }, "*");
          } catch (e) {
          }
        }
      }
      sendToSwift("insightIframeReady", {
        sessionId: state.insightSessionId,
        nodeId: state.insightCurrentNodeId
      });
      return;
    }
    case "insightDeepDiveClicked": {
      const sectionId = typeof payload.sectionId === "string" ? payload.sectionId : null;
      const topicIndex = typeof payload.topicIndex === "number" && Number.isInteger(payload.topicIndex) ? payload.topicIndex : null;
      if (!sectionId || topicIndex === null) {
        console.warn("[insight] insightDeepDiveClicked: invalid payload");
        return;
      }
      const skel = state.insightSkeleton;
      if (!skel || !Array.isArray(skel.sections)) return;
      const sec = skel.sections.find(function(s) {
        return s && s.id === sectionId;
      });
      if (!sec) {
        console.warn("[insight] insightDeepDiveClicked: unknown sectionId", sectionId);
        return;
      }
      const topics = Array.isArray(sec.deepDiveTopics) ? sec.deepDiveTopics : [];
      if (topicIndex < 0 || topicIndex >= topics.length) {
        console.warn("[insight] insightDeepDiveClicked: topicIndex out of bounds", topicIndex);
        return;
      }
      sendToSwift("insightDeepDiveClicked", {
        sessionId: state.insightSessionId,
        sectionId,
        topicIndex
      });
      return;
    }
    case "insightBreadcrumbClicked": {
      const nodeId = typeof payload.nodeId === "string" ? payload.nodeId : null;
      if (!nodeId || !UUID_REGEX.test(nodeId)) {
        console.warn("[insight] insightBreadcrumbClicked: nodeId not a UUID");
        return;
      }
      sendToSwift("insightBreadcrumbClicked", {
        sessionId: state.insightSessionId,
        nodeId
      });
      return;
    }
    case "insightRequestSave": {
      sendToSwift("insightRequestSave", { sessionId: state.insightSessionId });
      return;
    }
    case "insightRequestUp": {
      sendToSwift("insightRequestUp", { sessionId: state.insightSessionId });
      return;
    }
    case "insightRequestRegenerate": {
      sendToSwift("insightRequestRegenerate", { sessionId: state.insightSessionId });
      return;
    }
    case "insightRequestCustomDeepDive": {
      var topic = payload && typeof payload.topic === "string" ? payload.topic.trim() : "";
      if (!topic) return;
      sendToSwift("insightRequestCustomDeepDive", { sessionId: state.insightSessionId, topic });
      return;
    }
    case "insightRequestExploreAll": {
      var d = payload && typeof payload.depth === "number" ? payload.depth : 1;
      if (!(d >= 1 && d <= 3)) d = 1;
      sendToSwift("insightRequestExploreAll", { sessionId: state.insightSessionId, depth: d });
      return;
    }
    case "insightRequestRetrySection": {
      var secId = payload && typeof payload.sectionId === "string" ? payload.sectionId : "";
      if (!secId) return;
      sendToSwift("insightRequestRetrySection", { sessionId: state.insightSessionId, sectionId: secId });
      return;
    }
    case "insightDebug": {
      sendToSwift("jsError", {
        where: "iframe-debug-" + (payload.where || "?"),
        message: String(payload.msg || ""),
        source: "iframe",
        lineno: 0,
        colno: 0,
        stack: ""
      });
      return;
    }
  }
}, false);
;
window.setDocumentBase = function(baseURL) {
  state.documentBaseURL = baseURL;
};
window.setTheme = function(id, accent, definition) {
  applyTheme(id, accent, definition);
};
window.toggleSourceMode = function() {
  toggleMode();
};
window.scrollToHeading = function(id) {
  const heading = document.getElementById(id);
  if (heading && heading.offsetParent !== null) {
    heading.scrollIntoView({ behavior: "smooth", block: "start" });
    return;
  }
  const line = heading && heading.getAttribute("data-line");
  if (line && typeof window.documentGotoLine === "function") {
    window.documentGotoLine(parseInt(line, 10));
    return;
  }
  const known = (state.headings || []).find(function(h) {
    return h.id === id;
  });
  if (known && typeof window.scrollToHeadingText === "function") window.scrollToHeadingText(known.text);
};
window.scrollToText = function(searchText) {
  if (!searchText || !DOM.rendered) return;
  const elements = DOM.rendered.querySelectorAll("h1,h2,h3,h4,h5,h6,p,li,td,th,pre,blockquote,div");
  const needle = searchText.toLowerCase().trim();
  let found = null;
  for (const el of elements) {
    if (el.textContent && el.textContent.toLowerCase().includes(needle)) {
      found = el;
      break;
    }
  }
  if (found) {
    found.scrollIntoView({ behavior: "smooth", block: "center" });
    found.style.outline = "2px solid #569cd6";
    found.style.outlineOffset = "4px";
    found.style.transition = "outline 0.3s";
    setTimeout(() => {
      found.style.outline = "";
      found.style.outlineOffset = "";
    }, 2500);
  }
};
window.documentGotoLine = function(line) {
  if (state.mode === "preview") {
    const blocks = Array.from(DOM.rendered.querySelectorAll("[data-line]"));
    let best = null;
    blocks.forEach(function(el) {
      if (+el.getAttribute("data-line") <= line) best = el;
    });
    if (best) best.scrollIntoView({ block: "center" });
    return;
  }
  if (state.mode === "structured") switchToStructuredSource();
  if (state.mode !== "source" && state.mode !== "structured-source") return;
  const lines = DOM.editor.value.split("\n");
  const index = Math.max(0, Math.min(lines.length - 1, line - 1));
  const start = lines.slice(0, index).reduce(function(n, s) {
    return n + s.length + 1;
  }, 0);
  DOM.editor.setSelectionRange(start, start + lines[index].length);
  const height = parseFloat(getComputedStyle(DOM.editor).lineHeight) || 20;
  DOM.editor.scrollTop = Math.max(0, index * height - DOM.editor.clientHeight / 2);
};
window.getHTML = function() {
  return DOM.rendered.innerHTML;
};
window.getMarkdown = function() {
  return DOM.editor.value;
};
window.preparePrintLayout = function() {
  switchToPreview();
  DOM.toolbar.style.display = "none";
  document.querySelector(".editor-status").style.display = "none";
  document.documentElement.style.cssText += "; height: auto !important; overflow: visible !important;";
  document.body.style.cssText += "; height: auto !important; overflow: visible !important;";
  const container = document.querySelector(".editor-container");
  const content = document.querySelector(".editor-content");
  container.style.height = "auto";
  container.style.overflow = "visible";
  content.style.overflow = "visible";
  content.style.height = "auto";
  content.style.flex = "none";
  DOM.previewPane.style.overflow = "visible";
  DOM.previewPane.style.height = "auto";
  DOM.previewPane.style.flex = "none";
  DOM.rendered.style.overflow = "visible";
  DOM.rendered.style.height = "auto";
  DOM.rendered.style.flex = "none";
  DOM.rendered.style.padding = "40px";
  const style = document.createElement("style");
  style.id = "markview-print-styles";
  style.textContent = `
                img, .mermaid, table, pre, .admonition, blockquote {
                    break-inside: avoid !important;
                    page-break-inside: avoid !important;
                }
                h1, h2, h3, h4, h5, h6 {
                    break-after: avoid !important;
                    page-break-after: avoid !important;
                }
                table { table-layout: fixed !important; width: 100% !important; word-break: break-word !important; }
                pre { white-space: pre-wrap !important; word-break: break-word !important; }
                img { max-width: 100% !important; height: auto !important; }
                .mermaid, .mermaid svg { max-width: 100% !important; overflow: visible !important; }
            `;
  document.head.appendChild(style);
};
window.restoreEditLayout = function() {
  const ps = document.getElementById("markview-print-styles");
  if (ps) ps.remove();
  DOM.toolbar.style.display = "";
  document.querySelector(".editor-status").style.display = "";
  document.documentElement.style.height = "";
  document.documentElement.style.overflow = "";
  document.body.style.height = "";
  document.body.style.overflow = "";
  const container = document.querySelector(".editor-container");
  const content = document.querySelector(".editor-content");
  container.style.height = "";
  container.style.overflow = "";
  content.style.overflow = "";
  content.style.height = "";
  content.style.flex = "";
  DOM.previewPane.style.overflow = "";
  DOM.previewPane.style.height = "";
  DOM.previewPane.style.flex = "";
  DOM.rendered.style.overflow = "";
  DOM.rendered.style.height = "";
  DOM.rendered.style.flex = "";
  DOM.rendered.style.padding = "";
  switchToSource();
};
;
const CANVAS_PRESET_COLORS = {
  "1": "#fb464c",
  "2": "#e9973f",
  "3": "#e0de71",
  "4": "#44cf6e",
  "5": "#53dfdd",
  "6": "#a882ff"
};
const cv = {
  nodes: [],
  // parsed nodes (spec order preserved)
  edges: [],
  nodeById: /* @__PURE__ */ new Map(),
  tx: 0,
  ty: 0,
  scale: 1,
  minScale: 0.05,
  maxScale: 4,
  selectedId: null,
  // node or edge id
  pan: null,
  // active drag-pan state {x, y, tx, ty}
  viewport: null,
  world: null,
  svg: null,
  propsPanel: null,
  zoomLabel: null
};
const CANVAS_COLOR_SHAPE = /^(?:#[0-9a-f]{3,8}|(?:rgb|hsl)a?\(\s*[\w.%\s,\/-]+\)|[a-z]{3,30})$/i;
function canvasColor(color, fallback) {
  if (!color) return fallback;
  const value = String(CANVAS_PRESET_COLORS[color] || color).trim();
  return CANVAS_COLOR_SHAPE.test(value) && CSS.supports("color", value) ? value : fallback;
}
window.renderCanvasView = function() {
  document.body.classList.add("canvas-mode");
  let data;
  try {
    data = JSON.parse(state.markdown);
    if (!data || typeof data !== "object") throw new Error("Root is not an object");
  } catch (e) {
    window.leaveCanvasView();
    DOM.rendered.innerHTML = '<div class="struct-error">Canvas Parse Error: ' + window.mvKit.escapeHtml(e.message) + '</div><pre class="language-json" style="padding:12px;margin:0;overflow:auto;"><code>' + window.mvKit.escapeHtml(state.markdown) + "</code></pre>";
    return;
  }
  cv.nodes = Array.isArray(data.nodes) ? data.nodes.filter((n) => n && n.id != null) : [];
  cv.edges = Array.isArray(data.edges) ? data.edges.filter((e) => e && e.id != null) : [];
  cv.nodeById = new Map(cv.nodes.map((n) => [String(n.id), n]));
  cv.selectedId = null;
  buildCanvasDOM();
  canvasZoomFit();
  sendCanvasHeadings();
};
window.leaveCanvasView = function() {
  document.body.classList.remove("canvas-mode");
};
const _cvOrigSetContent = window.setContent;
window.setContent = function(markdown) {
  window.leaveCanvasView();
  state.fileType = "markdown";
  DOM.rendered.contentEditable = "true";
  _cvOrigSetContent(markdown);
};
const _cvOrigScrollToHeading = window.scrollToHeading;
window.scrollToHeading = function(id) {
  if (state.fileType === "canvas" && typeof id === "string" && id.indexOf("cv-") === 0) {
    canvasFocusNode(id.slice(3));
    return;
  }
  if (_cvOrigScrollToHeading) _cvOrigScrollToHeading(id);
};
function buildCanvasDOM() {
  DOM.rendered.innerHTML = "";
  const viewport = document.createElement("div");
  viewport.className = "canvas-viewport";
  const toolbar = document.createElement("div");
  toolbar.className = "canvas-toolbar";
  toolbar.innerHTML = '<button data-act="fit" title="Zoom to fit (double-click background)">Fit</button><button data-act="100" title="Actual size">100%</button><button data-act="out" title="Zoom out">\u2212</button><span class="canvas-zoom-label">100%</span><button data-act="in" title="Zoom in">+</button><span class="canvas-stats">' + cv.nodes.length + " nodes \xB7 " + cv.edges.length + ' edges</span><span class="spacer"></span><button data-act="source" title="Show raw JSON">Source \u2197</button>';
  toolbar.addEventListener("click", (ev) => {
    const act = ev.target.getAttribute && ev.target.getAttribute("data-act");
    if (!act) return;
    if (act === "fit") canvasZoomFit();
    else if (act === "100") canvasSetZoom(1);
    else if (act === "out") canvasZoomBy(1 / 1.25);
    else if (act === "in") canvasZoomBy(1.25);
    else if (act === "source") window.toggleStructMode();
  });
  const world = document.createElement("div");
  world.className = "canvas-world";
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("class", "canvas-edges");
  svg.setAttribute("width", "1");
  svg.setAttribute("height", "1");
  world.appendChild(svg);
  const groups = cv.nodes.filter((n) => n.type === "group").sort((a, b) => b.width * b.height - a.width * a.height);
  const others = cv.nodes.filter((n) => n.type !== "group");
  groups.concat(others).forEach((n) => world.appendChild(buildCanvasNode(n)));
  cv.edges.forEach((e) => drawCanvasEdge(svg, e));
  const props = document.createElement("div");
  props.className = "canvas-props";
  props.style.display = "none";
  viewport.appendChild(world);
  viewport.appendChild(toolbar);
  viewport.appendChild(props);
  DOM.rendered.appendChild(viewport);
  cv.viewport = viewport;
  cv.world = world;
  cv.svg = svg;
  cv.propsPanel = props;
  cv.zoomLabel = toolbar.querySelector(".canvas-zoom-label");
  wireCanvasInteractions();
}
function buildCanvasNode(n) {
  const el = document.createElement("div");
  el.className = "canvas-node canvas-node-" + (n.type || "text");
  el.setAttribute("data-node-id", String(n.id));
  el.style.left = (n.x || 0) + "px";
  el.style.top = (n.y || 0) + "px";
  el.style.width = (n.width || 0) + "px";
  el.style.height = (n.height || 0) + "px";
  const color = canvasColor(n.color, "");
  if (color) {
    el.style.borderColor = color;
    el.style.setProperty("--cv-node-color", color);
  }
  if (n.type === "group") {
    const label = document.createElement("div");
    label.className = "canvas-group-label";
    label.textContent = n.label || "";
    el.appendChild(label);
  } else if (n.type === "text") {
    const content = document.createElement("div");
    content.className = "canvas-node-content markdown-body";
    try {
      if (typeof md !== "undefined" && md) {
        const renderedCanvasHTML = md.render(String(n.text || ""));
        content.innerHTML = typeof window.sanitizeMarkdownHTML === "function" ? window.sanitizeMarkdownHTML(renderedCanvasHTML) : '<pre class="sanitization-error">' + window.mvKit.escapeHtml(String(n.text || "")) + "</pre>";
      } else {
        content.innerHTML = "<pre>" + window.mvKit.escapeHtml(String(n.text || "")) + "</pre>";
      }
    } catch (e) {
      content.innerHTML = "<pre>" + window.mvKit.escapeHtml(String(n.text || "")) + "</pre>";
    }
    el.appendChild(content);
  } else if (n.type === "file") {
    const path = String(n.file || "");
    const name = path.split("/").pop();
    const ext = (name.indexOf(".") >= 0 ? name.split(".").pop() : "").toLowerCase();
    const icon = ["png", "jpg", "jpeg", "gif", "svg", "webp", "bmp"].includes(ext) ? "\u{1F5BC}" : ext === "canvas" ? "\u{1F5FA}" : ext === "pdf" ? "\u{1F4D5}" : "\u{1F4C4}";
    el.innerHTML = '<div class="canvas-node-content canvas-file"><div class="canvas-file-icon">' + icon + '</div><div class="canvas-file-name">' + window.mvKit.escapeHtml(name) + '</div><div class="canvas-file-path">' + window.mvKit.escapeHtml(path) + (n.subpath ? window.mvKit.escapeHtml(String(n.subpath)) : "") + '</div><div class="canvas-file-hint">double-click to open</div></div>';
    el.addEventListener("dblclick", (ev) => {
      ev.stopPropagation();
      sendToSwift("canvasOpenFile", { path });
    });
  } else if (n.type === "link") {
    const url = String(n.url || "");
    el.innerHTML = '<div class="canvas-node-content canvas-link"><div class="canvas-file-icon">\u{1F310}</div><div class="canvas-link-url">' + window.mvKit.escapeHtml(url) + '</div><div class="canvas-file-hint">double-click to open</div></div>';
    el.addEventListener("dblclick", (ev) => {
      ev.stopPropagation();
      if (/^https?:\/\//i.test(url)) sendToSwift("linkClicked", { href: url });
    });
  }
  return el;
}
function canvasAnchor(n, side) {
  const x = n.x || 0, y = n.y || 0, w = n.width || 0, h = n.height || 0;
  switch (side) {
    case "top":
      return { x: x + w / 2, y, dx: 0, dy: -1 };
    case "bottom":
      return { x: x + w / 2, y: y + h, dx: 0, dy: 1 };
    case "left":
      return { x, y: y + h / 2, dx: -1, dy: 0 };
    case "right":
      return { x: x + w, y: y + h / 2, dx: 1, dy: 0 };
  }
  return null;
}
function canvasBestSide(from, to) {
  const fx = (from.x || 0) + (from.width || 0) / 2, fy = (from.y || 0) + (from.height || 0) / 2;
  const tx = (to.x || 0) + (to.width || 0) / 2, ty = (to.y || 0) + (to.height || 0) / 2;
  const dx = tx - fx, dy = ty - fy;
  if (Math.abs(dx) > Math.abs(dy)) return dx > 0 ? "right" : "left";
  return dy > 0 ? "bottom" : "top";
}
function drawCanvasEdge(svg, e) {
  const from = cv.nodeById.get(String(e.fromNode));
  const to = cv.nodeById.get(String(e.toNode));
  if (!from || !to) return;
  const a = canvasAnchor(from, e.fromSide || canvasBestSide(from, to));
  const b = canvasAnchor(to, e.toSide || canvasBestSide(to, from));
  if (!a || !b) return;
  const dist = Math.hypot(b.x - a.x, b.y - a.y);
  const k = Math.min(Math.max(dist * 0.35, 40), 220);
  const c1 = { x: a.x + a.dx * k, y: a.y + a.dy * k };
  const c2 = { x: b.x + b.dx * k, y: b.y + b.dy * k };
  const color = canvasColor(e.color, "var(--cv-edge-color)");
  const ns = "http://www.w3.org/2000/svg";
  const g = document.createElementNS(ns, "g");
  g.setAttribute("class", "canvas-edge");
  g.setAttribute("data-edge-id", String(e.id));
  const d = "M" + a.x + "," + a.y + " C" + c1.x + "," + c1.y + " " + c2.x + "," + c2.y + " " + b.x + "," + b.y;
  const hit = document.createElementNS(ns, "path");
  hit.setAttribute("d", d);
  hit.setAttribute("class", "canvas-edge-hit");
  const path = document.createElementNS(ns, "path");
  path.setAttribute("d", d);
  path.setAttribute("class", "canvas-edge-line");
  path.style.stroke = color;
  g.appendChild(hit);
  g.appendChild(path);
  if ((e.toEnd || "arrow") === "arrow") g.appendChild(canvasArrowHead(b, c2, color));
  if ((e.fromEnd || "none") === "arrow") g.appendChild(canvasArrowHead(a, c1, color));
  if (e.label) {
    const mid = canvasBezierPoint(a, c1, c2, b, 0.5);
    const label = document.createElementNS(ns, "text");
    label.setAttribute("x", mid.x);
    label.setAttribute("y", mid.y);
    label.setAttribute("class", "canvas-edge-label");
    label.textContent = String(e.label);
    g.appendChild(label);
  }
  svg.appendChild(g);
}
function canvasBezierPoint(p0, p1, p2, p3, t) {
  const u = 1 - t;
  return {
    x: u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
    y: u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
  };
}
function canvasArrowHead(tip, ctrl, color) {
  let dx = tip.x - ctrl.x, dy = tip.y - ctrl.y;
  const len = Math.hypot(dx, dy) || 1;
  dx /= len;
  dy /= len;
  const size = 10;
  const p1 = { x: tip.x - dx * size - dy * size * 0.5, y: tip.y - dy * size + dx * size * 0.5 };
  const p2 = { x: tip.x - dx * size + dy * size * 0.5, y: tip.y - dy * size - dx * size * 0.5 };
  const poly = document.createElementNS("http://www.w3.org/2000/svg", "polygon");
  poly.setAttribute("points", tip.x + "," + tip.y + " " + p1.x + "," + p1.y + " " + p2.x + "," + p2.y);
  poly.setAttribute("class", "canvas-edge-arrow");
  poly.style.fill = color;
  return poly;
}
function canvasApplyTransform() {
  cv.world.style.transform = "translate(" + cv.tx + "px," + cv.ty + "px) scale(" + cv.scale + ")";
  if (cv.zoomLabel) cv.zoomLabel.textContent = Math.round(cv.scale * 100) + "%";
}
function canvasContentBounds() {
  if (!cv.nodes.length) return { x: 0, y: 0, w: 100, h: 100 };
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  cv.nodes.forEach((n) => {
    minX = Math.min(minX, n.x || 0);
    minY = Math.min(minY, n.y || 0);
    maxX = Math.max(maxX, (n.x || 0) + (n.width || 0));
    maxY = Math.max(maxY, (n.y || 0) + (n.height || 0));
  });
  return { x: minX, y: minY, w: Math.max(maxX - minX, 1), h: Math.max(maxY - minY, 1) };
}
function canvasZoomFit(retryCount) {
  const vp = cv.viewport.getBoundingClientRect();
  if ((vp.width < 40 || vp.height < 40) && (retryCount || 0) < 30) {
    requestAnimationFrame(() => canvasZoomFit((retryCount || 0) + 1));
    return;
  }
  const b = canvasContentBounds();
  const s = Math.min(Math.min(vp.width / b.w, vp.height / b.h) * 0.9, 1.5);
  cv.scale = Math.max(cv.minScale, Math.min(cv.maxScale, s));
  cv.tx = (vp.width - b.w * cv.scale) / 2 - b.x * cv.scale;
  cv.ty = (vp.height - b.h * cv.scale) / 2 - b.y * cv.scale;
  canvasApplyTransform();
}
function canvasSetZoom(s, pivot) {
  const vp = cv.viewport.getBoundingClientRect();
  const p = pivot || { x: vp.width / 2, y: vp.height / 2 };
  s = Math.max(cv.minScale, Math.min(cv.maxScale, s));
  const wx = (p.x - cv.tx) / cv.scale, wy = (p.y - cv.ty) / cv.scale;
  cv.scale = s;
  cv.tx = p.x - wx * s;
  cv.ty = p.y - wy * s;
  canvasApplyTransform();
}
function canvasZoomBy(factor, pivot) {
  canvasSetZoom(cv.scale * factor, pivot);
}
function canvasFocusNode(nodeId, zoom) {
  const n = cv.nodeById.get(String(nodeId));
  if (!n || !cv.viewport) return;
  const vp = cv.viewport.getBoundingClientRect();
  const s = zoom || Math.max(Math.min(cv.scale, 1), 0.5);
  cv.scale = Math.max(cv.minScale, Math.min(cv.maxScale, s));
  cv.tx = vp.width / 2 - ((n.x || 0) + (n.width || 0) / 2) * cv.scale;
  cv.ty = vp.height / 2 - ((n.y || 0) + (n.height || 0) / 2) * cv.scale;
  canvasApplyTransform();
  canvasSelect(String(nodeId), "node");
}
function wireCanvasInteractions() {
  const vpEl = cv.viewport;
  vpEl.addEventListener("wheel", (ev) => {
    if (!ev.ctrlKey && !ev.metaKey) {
      const scrollable = ev.target.closest && ev.target.closest(".canvas-node.selected .canvas-node-content");
      if (scrollable && scrollable.scrollHeight > scrollable.clientHeight) return;
    }
    ev.preventDefault();
    const rect = vpEl.getBoundingClientRect();
    const pivot = { x: ev.clientX - rect.left, y: ev.clientY - rect.top };
    if (ev.shiftKey && !ev.ctrlKey && !ev.metaKey) {
      cv.tx -= ev.deltaX;
      cv.ty -= ev.deltaY;
      canvasApplyTransform();
    } else {
      canvasZoomBy(Math.exp(-ev.deltaY * 0.01), pivot);
    }
  }, { passive: false });
  vpEl.addEventListener("mousedown", (ev) => {
    const onChrome = ev.target.closest(".canvas-toolbar, .canvas-props");
    if (onChrome) return;
    const onNode = ev.target.closest(".canvas-node, .canvas-edge");
    if (ev.button === 0 && onNode) return;
    if (ev.button !== 0 && ev.button !== 1) return;
    cv.pan = { x: ev.clientX, y: ev.clientY, tx: cv.tx, ty: cv.ty };
    vpEl.classList.add("panning");
    ev.preventDefault();
  });
  window.addEventListener("mousemove", canvasPanMove);
  window.addEventListener("mouseup", canvasPanEnd);
  vpEl.addEventListener("click", (ev) => {
    if (ev.target.closest(".canvas-toolbar, .canvas-props")) return;
    const nodeEl = ev.target.closest(".canvas-node");
    const edgeEl = ev.target.closest(".canvas-edge");
    if (nodeEl) canvasSelect(nodeEl.getAttribute("data-node-id"), "node");
    else if (edgeEl) canvasSelect(edgeEl.getAttribute("data-edge-id"), "edge");
    else canvasSelect(null);
  });
  vpEl.addEventListener("dblclick", (ev) => {
    if (ev.target.closest(".canvas-toolbar, .canvas-props")) return;
    const nodeEl = ev.target.closest(".canvas-node");
    if (nodeEl) {
      const n = cv.nodeById.get(nodeEl.getAttribute("data-node-id"));
      if (n && (n.type === "text" || n.type === "group")) canvasFocusNode(n.id, 1);
      return;
    }
    canvasZoomFit();
  });
  document.addEventListener("keydown", canvasKeyHandler);
}
function canvasPanMove(ev) {
  if (!cv.pan) return;
  cv.tx = cv.pan.tx + (ev.clientX - cv.pan.x);
  cv.ty = cv.pan.ty + (ev.clientY - cv.pan.y);
  canvasApplyTransform();
}
function canvasPanEnd() {
  if (!cv.pan) return;
  cv.pan = null;
  if (cv.viewport) cv.viewport.classList.remove("panning");
}
function canvasKeyHandler(ev) {
  if (state.fileType !== "canvas" || state.mode !== "structured") return;
  if (ev.key === "Escape") canvasSelect(null);
}
function canvasSelect(id, kind) {
  cv.selectedId = id;
  cv.viewport.querySelectorAll(".canvas-node.selected, .canvas-edge.selected").forEach((el) => el.classList.remove("selected"));
  if (!id) {
    cv.propsPanel.style.display = "none";
    return;
  }
  const sel = kind === "node" ? cv.viewport.querySelector('.canvas-node[data-node-id="' + CSS.escape(id) + '"]') : cv.viewport.querySelector('.canvas-edge[data-edge-id="' + CSS.escape(id) + '"]');
  if (sel) sel.classList.add("selected");
  renderCanvasProps(id, kind);
}
function canvasPropRow(key, valueHtml) {
  return '<div class="canvas-prop"><span class="canvas-prop-key">' + key + '</span><span class="canvas-prop-value">' + valueHtml + "</span></div>";
}
function renderCanvasProps(id, kind) {
  let html = "";
  if (kind === "node") {
    const n = cv.nodeById.get(String(id));
    if (!n) return;
    html += '<div class="canvas-props-title">' + window.mvKit.escapeHtml(n.type || "text") + ' node<button class="canvas-props-close" title="Close (Esc)">\u2715</button></div>';
    html += canvasPropRow("id", window.mvKit.escapeHtml(String(n.id)));
    html += canvasPropRow("x", String(n.x || 0)) + canvasPropRow("y", String(n.y || 0));
    html += canvasPropRow("width", String(n.width || 0)) + canvasPropRow("height", String(n.height || 0));
    if (n.color) {
      const c = canvasColor(n.color, "");
      html += canvasPropRow("color", '<span class="canvas-swatch" style="background:' + window.mvKit.escapeHtml(c) + '"></span>' + window.mvKit.escapeHtml(String(n.color)));
    }
    if (n.type === "file") {
      html += canvasPropRow("file", window.mvKit.escapeHtml(String(n.file || "")));
      if (n.subpath) html += canvasPropRow("subpath", window.mvKit.escapeHtml(String(n.subpath)));
    } else if (n.type === "link") {
      html += canvasPropRow("url", window.mvKit.escapeHtml(String(n.url || "")));
    } else if (n.type === "group") {
      if (n.label) html += canvasPropRow("label", window.mvKit.escapeHtml(String(n.label)));
      if (n.background) html += canvasPropRow("background", window.mvKit.escapeHtml(String(n.background)));
      if (n.backgroundStyle) html += canvasPropRow("bg style", window.mvKit.escapeHtml(String(n.backgroundStyle)));
    } else if (n.type === "text" || n.text != null) {
      const text = String(n.text || "");
      html += canvasPropRow("length", text.length + " chars");
      html += '<div class="canvas-prop-block"><pre>' + window.mvKit.escapeHtml(text) + "</pre></div>";
    }
  } else {
    const e = cv.edges.find((x) => String(x.id) === String(id));
    if (!e) return;
    const fromN = cv.nodeById.get(String(e.fromNode));
    const toN = cv.nodeById.get(String(e.toNode));
    html += '<div class="canvas-props-title">edge<button class="canvas-props-close" title="Close (Esc)">\u2715</button></div>';
    html += canvasPropRow("id", window.mvKit.escapeHtml(String(e.id)));
    html += canvasPropRow("from", window.mvKit.escapeHtml(canvasNodeTitle(fromN) || String(e.fromNode)) + (e.fromSide ? " \xB7 " + window.mvKit.escapeHtml(e.fromSide) : ""));
    html += canvasPropRow("to", window.mvKit.escapeHtml(canvasNodeTitle(toN) || String(e.toNode)) + (e.toSide ? " \xB7 " + window.mvKit.escapeHtml(e.toSide) : ""));
    html += canvasPropRow("ends", window.mvKit.escapeHtml((e.fromEnd || "none") + " \u2192 " + (e.toEnd || "arrow")));
    if (e.label) html += canvasPropRow("label", window.mvKit.escapeHtml(String(e.label)));
    if (e.color) {
      const c = canvasColor(e.color, "");
      html += canvasPropRow("color", '<span class="canvas-swatch" style="background:' + window.mvKit.escapeHtml(c) + '"></span>' + window.mvKit.escapeHtml(String(e.color)));
    }
  }
  cv.propsPanel.innerHTML = html;
  cv.propsPanel.style.display = "block";
  const close = cv.propsPanel.querySelector(".canvas-props-close");
  if (close) close.addEventListener("click", () => canvasSelect(null));
}
function canvasNodeTitle(n) {
  if (!n) return "";
  if (n.type === "group") return n.label || "Group";
  if (n.type === "file") return String(n.file || "").split("/").pop();
  if (n.type === "link") return String(n.url || "");
  const text = String(n.text || "").trim();
  const firstLine = text.split("\n")[0].replace(/^#+\s*/, "").replace(/[*_`~]/g, "");
  return firstLine.slice(0, 60) || "Text";
}
function canvasNodeInGroup(n, groups) {
  const cx = (n.x || 0) + (n.width || 0) / 2, cy = (n.y || 0) + (n.height || 0) / 2;
  return groups.some((g) => cx >= g.x && cx <= g.x + g.width && cy >= g.y && cy <= g.y + g.height);
}
function sendCanvasHeadings() {
  const groups = cv.nodes.filter((n) => n.type === "group");
  const headings = cv.nodes.map((n) => ({
    id: "cv-" + String(n.id),
    level: n.type === "group" ? 1 : canvasNodeInGroup(n, groups) ? 2 : 1,
    text: canvasNodeTitle(n)
  }));
  sendToSwift("headingsUpdated", headings);
}
;
window.MVPanels = {
  /**
   * @param {Object} o
   * @param {HTMLElement} o.handle   element the user drags
   * @param {HTMLElement} o.panel    element whose width changes (right-hand side)
   * @param {HTMLElement} o.host     row containing the panel; its right edge anchors the drag
   * @param {string} o.key           localStorage key for the width
   * @param {number} o.width         default width in px
   * @param {number} [o.min=200]     narrowest width
   * @param {number} [o.reserve=240] room always left for the rest of the row
   * @param {Function} [o.onResize]  called after every width change
   */
  resizable: function(o) {
    const min = o.min || 200, reserve = o.reserve || 240;
    function set(width, save) {
      const max = Math.max(min, o.host.clientWidth - reserve);
      const value = Math.round(Math.min(max, Math.max(min, width)));
      o.panel.style.width = value + "px";
      if (save) {
        try {
          localStorage.setItem(o.key, value);
        } catch (e) {
        }
      }
      if (o.onResize) o.onResize(value);
    }
    try {
      const saved = parseInt(localStorage.getItem(o.key), 10);
      if (saved > 0) o.panel.style.width = saved + "px";
    } catch (e) {
    }
    o.handle.title = o.handle.title || "Drag to resize \xB7 double-click to reset";
    o.handle.addEventListener("mousedown", function(e) {
      if (e.button !== 0) return;
      e.preventDefault();
      document.body.classList.add("mv-resizing");
      const right = o.host.getBoundingClientRect().right;
      function move(ev) {
        ev.preventDefault();
        set(right - ev.clientX, false);
      }
      function up(ev) {
        window.removeEventListener("mousemove", move, true);
        window.removeEventListener("mouseup", up, true);
        document.body.classList.remove("mv-resizing");
        set(right - ev.clientX, true);
      }
      window.addEventListener("mousemove", move, true);
      window.addEventListener("mouseup", up, true);
    });
    o.handle.addEventListener("dblclick", function() {
      set(o.width, true);
    });
    return { set };
  }
};
;
(function() {
  const container = document.getElementById("code-container");
  const main = document.createElement("div");
  main.className = "code-main";
  const explainButton = document.createElement("button");
  explainButton.className = "code-explain-btn";
  explainButton.textContent = "\u2726 Explain";
  explainButton.title = "Explain this file section by section (AI)";
  main.appendChild(explainButton);
  const editButton = document.createElement("button");
  editButton.className = "code-edit-btn";
  editButton.textContent = "\u270E Edit";
  editButton.title = "Edit this file (\u2318S saves it)";
  editButton.hidden = true;
  main.appendChild(editButton);
  const documentButton = document.createElement("button");
  documentButton.className = "code-document-btn";
  documentButton.textContent = "\u2190 Document";
  documentButton.title = "Back to the formatted document (editable)";
  documentButton.hidden = true;
  main.appendChild(documentButton);
  const docExplainButton = document.createElement("button");
  docExplainButton.className = "code-explain-btn doc-explain-btn";
  docExplainButton.textContent = "\u2726 Explain";
  docExplainButton.title = "Explain this file section by section, with importance, freshness and filters";
  DOM.previewPane.appendChild(docExplainButton);
  window.explainCurrentFile = function() {
    notesHidden = false;
    postCode("notesView", { show: true, explain: true });
  };
  const sourceExplainButton = docExplainButton.cloneNode(true);
  sourceExplainButton.classList.remove("doc-explain-btn");
  DOM.editorPane.appendChild(sourceExplainButton);
  sourceExplainButton.addEventListener("click", function() {
    window.explainCurrentFile();
  });
  const zoomBar = document.createElement("div");
  zoomBar.className = "code-zoom";
  zoomBar.innerHTML = '<button data-z="out" title="Zoom out">\u2212</button><span class="code-zoom-level">100%</span><button data-z="in" title="Zoom in">+</button><button data-z="fit" title="Fit the whole file">Fit file</button><button data-z="reset" title="Actual size">1:1</button>';
  main.appendChild(zoomBar);
  const bands = document.createElement("div");
  bands.className = "code-bands";
  bands.innerHTML = '<div class="code-bands-track"></div>';
  const bandsTrack = bands.firstChild;
  const heat = document.createElement("div");
  heat.className = "code-heat";
  heat.innerHTML = '<div class="code-heat-view"></div>';
  const heatView = heat.firstChild;
  main.appendChild(bands);
  main.appendChild(heat);
  let baseSize = 13;
  try {
    baseSize = parseFloat(localStorage.getItem("markview-font-size")) || 13;
  } catch (e) {
  }
  let codeSize = baseSize;
  container.style.setProperty("--mv-code-size", codeSize + "px");
  const notes = document.createElement("aside");
  notes.className = "code-notes";
  notes.hidden = true;
  notes.innerHTML = '<div class="code-notes-head"><select class="code-lens" title="What the notes show"></select><span class="code-notes-status"></span><button class="code-notes-info" title="">\u24D8</button><button class="code-notes-redo" title="Explain again">\u21BB</button><button class="code-notes-close" title="Hide notes">\u2715</button></div><form class="temp-filter code-temp-filter" title="A one-off AI filter: applied now, not saved"><input placeholder="\u26A1 Quick AI filter, e.g. payment flow"><button type="button" hidden title="Clear">\u2715</button></form><div class="code-notes-legend"></div><form class="code-new-filter" hidden><input placeholder="Topic or question, e.g. payment flow"><button type="submit">Add</button></form><div class="code-notes-viewport"><div class="code-notes-track"></div></div>';
  container.appendChild(main);
  container.appendChild(notes);
  const resizer = document.createElement("div");
  resizer.className = "code-notes-resizer";
  notes.appendChild(resizer);
  window.MVPanels.resizable({
    handle: resizer,
    panel: notes,
    host: container,
    key: "markview-code-notes-width",
    width: 320,
    onResize: function() {
      queueLayout();
    }
  });
  const lens = notes.querySelector(".code-lens");
  const track = notes.querySelector(".code-notes-track");
  const notesStatus = notes.querySelector(".code-notes-status");
  const info = notes.querySelector(".code-notes-info");
  const viewport = notes.querySelector(".code-notes-viewport");
  const legend = notes.querySelector(".code-notes-legend");
  let notesState = null;
  let pendingLens = null;
  let notesHidden = false;
  let marked = [];
  let layoutQueued = false;
  let viewer = null;
  let loading = null;
  let docPending = false;
  function createMarkdownViewer(host) {
    const scroller = document.createElement("div");
    scroller.className = "md-viewer";
    const body = document.createElement("div");
    body.className = "markdown-body md-viewer-body";
    scroller.appendChild(body);
    host.appendChild(scroller);
    const listeners = [];
    let blocks = [];
    function notify() {
      listeners.forEach(function(fn) {
        fn();
      });
    }
    scroller.addEventListener("scroll", notify, { passive: true });
    if (window.ResizeObserver) new ResizeObserver(notify).observe(scroller);
    function measure() {
      blocks = Array.from(body.querySelectorAll("[data-line]")).map(function(el) {
        return { line: +el.getAttribute("data-line"), el };
      }).sort(function(a, b) {
        return a.line - b.line;
      });
    }
    function top(el) {
      return el.getBoundingClientRect().top - scroller.getBoundingClientRect().top + scroller.scrollTop;
    }
    function lineTop(n) {
      let best = null;
      for (let i = 0; i < blocks.length && blocks[i].line <= n; i++) best = blocks[i];
      return best ? top(best.el) : 0;
    }
    function lineBottom(n) {
      const next = blocks.find(function(b) {
        return b.line > n;
      });
      return next ? top(next.el) : scroller.scrollHeight;
    }
    return {
      kind: "markdown",
      element: scroller,
      scrollerEl: function() {
        return scroller;
      },
      setDoc: function(text) {
        const fm = text.match(/^---\r?\n[\s\S]*?\r?\n---\r?\n/);
        const offset = fm ? fm[0].split("\n").length - 1 : 0;
        const source = fm ? text.slice(fm[0].length) : text;
        let html;
        try {
          const tokens = md.parse(source, {});
          tokens.forEach(function(t) {
            if (t.map && t.block && t.nesting >= 0) t.attrSet("data-line", String(t.map[0] + 1 + offset));
          });
          const renderedCodeMD = md.renderer.render(tokens, md.options, {});
          html = typeof window.sanitizeMarkdownHTML === "function" ? window.sanitizeMarkdownHTML(renderedCodeMD) : '<pre class="sanitization-error">' + window.mvKit.escapeHtml(source) + "</pre>";
        } catch (e) {
          html = "<pre>" + window.mvKit.escapeHtml(source) + "</pre>";
        }
        body.innerHTML = html;
        MarkViewDocumentFiles.resolvePictures(body, state.documentBaseURL);
        scroller.scrollTop = 0;
        measure();
        notify();
      },
      setTheme: function() {
      },
      onLayout: function(fn) {
        listeners.push(fn);
      },
      refresh: function() {
        measure();
        notify();
      },
      /** Scale the whole text, images included, so "Fit file" really fits. */
      setScale: function(scale) {
        body.style.zoom = String(scale);
        measure();
        notify();
      },
      fitScale: function(scale) {
        return scale * Math.max(0.01, (scroller.clientHeight - 20) / Math.max(1, scroller.scrollHeight));
      },
      viewportHeight: function() {
        return scroller.clientHeight;
      },
      lineCount: function() {
        return blocks.length ? blocks[blocks.length - 1].line : 1;
      },
      geometry: function() {
        return { height: scroller.scrollHeight, scrollTop: scroller.scrollTop, lineTop, lineBottom };
      },
      gotoLine: function(start, end) {
        scroller.scrollTop = Math.max(0, lineTop(start) - 24);
        blocks.forEach(function(b) {
          if (b.line >= start && b.line <= (end || start)) {
            b.el.classList.add("md-flash");
            setTimeout(function() {
              b.el.classList.remove("md-flash");
            }, 1600);
          }
        });
      },
      openSearch: function() {
      }
    };
  }
  let codeViewer = null, mdViewer = null;
  function scrollerEl() {
    return viewer && viewer.scrollerEl ? viewer.scrollerEl() : main.querySelector(".cm-scroller");
  }
  function loadBundle() {
    if (window.MVCode) return Promise.resolve();
    if (loading) return loading;
    loading = new Promise(function(resolve, reject) {
      const script = document.createElement("script");
      script.src = "vendor/js/codemirror.bundle.js";
      script.onload = function() {
        resolve();
      };
      script.onerror = function() {
        loading = null;
        reject(new Error("codemirror.bundle.js failed to load"));
      };
      document.head.appendChild(script);
    });
    return loading;
  }
  Object.assign(window, { MVLoadCode: loadBundle });
  function isDark() {
    return document.documentElement.getAttribute("data-theme") === "dark";
  }
  function enterCodeView(language) {
    if (typeof leaveInsightView === "function") leaveInsightView();
    if (typeof window.leaveCanvasView === "function") window.leaveCanvasView();
    state.mode = "code";
    state.fileType = "code";
    DOM.editorPane.style.display = "none";
    DOM.previewPane.style.display = "none";
    document.getElementById("wysiwyg-toolbar").style.display = "none";
    document.body.classList.add("code-mode");
    container.classList.add("visible");
    DOM.statusMode.textContent = language ? language.toUpperCase() : "TEXT";
  }
  let editing = false;
  function setEditing(on) {
    const was = editing;
    editing = !!on && !!codeViewer && viewer === codeViewer;
    if (codeViewer && codeViewer.isEditable && codeViewer.isEditable() !== editing) codeViewer.setEditable(editing);
    editButton.textContent = editing ? "\u2713 Done" : "\u270E Edit";
    editButton.title = editing ? "Stop editing (the changes stay in the tab until \u2318S)" : "Edit this file (\u2318S saves it)";
    main.classList.toggle("code-editing", editing);
    if (editing) {
      notesState = null;
      renderNotes();
      explainButton.hidden = true;
    } else if (was) renderNotes();
  }
  editButton.addEventListener("click", function() {
    setEditing(!editing);
  });
  window.leaveCodeView = function() {
    if (!container.classList.contains("visible")) return;
    setEditing(false);
    if (window.closeCodeFloating) window.closeCodeFloating();
    container.classList.remove("visible");
    document.body.classList.remove("code-mode");
    document.getElementById("wysiwyg-toolbar").style.display = "";
  };
  window.setCodeContent = function(text, language, fileName, returnLabel) {
    if (window.closeCodeFloating) window.closeCodeFloating();
    if (fileName !== currentFile && typeof closeAI === "function") closeAI();
    currentFile = fileName || null;
    enterCodeView(language);
    documentButton.hidden = !returnLabel && language !== "markdown";
    documentButton.textContent = "\u2190 " + (returnLabel || "Document");
    documentButton.title = "Back to the file viewer";
    setEditing(false);
    editButton.hidden = language === "markdown" || !!returnLabel;
    main.classList.toggle("code-md", language === "markdown");
    state.markdown = text;
    docPending = true;
    notesState = null;
    renderNotes();
    if (language === "markdown") {
      if (!mdViewer) {
        mdViewer = createMarkdownViewer(main);
        mdViewer.onLayout(queueLayout);
      }
      viewer = mdViewer;
      mdViewer.element.hidden = false;
      if (codeViewer && codeViewer.element) codeViewer.element.hidden = true;
      mdViewer.setScale(codeSize / baseSize);
      mdViewer.setDoc(text);
      docPending = false;
      if (window.pendingCodeLine) {
        const target = window.pendingCodeLine;
        window.pendingCodeLine = null;
        viewer.gotoLine(target.line, target.endLine);
      }
      return;
    }
    if (mdViewer) mdViewer.element.hidden = true;
    loadBundle().then(function() {
      if (!codeViewer) {
        codeViewer = window.MVCode.create(main, { doc: text, language, dark: isDark() });
        codeViewer.onLayout(queueLayout);
        codeViewer.onChange(function(text2) {
          state.markdown = text2;
          sendToSwift("contentChanged", { markdown: text2, html: "" });
        });
        codeViewer.element = main.querySelector(".cm-editor");
      } else {
        codeViewer.setDoc(text, language);
        codeViewer.setTheme(isDark());
      }
      if (codeViewer.element) codeViewer.element.hidden = false;
      viewer = codeViewer;
      docPending = false;
      if (window.pendingCodeLine) {
        const target = window.pendingCodeLine;
        window.pendingCodeLine = null;
        viewer.gotoLine(target.line, target.endLine);
      }
    }).catch(function(error) {
      container.textContent = "Code viewer failed to load: " + error.message;
    });
  };
  window.codeGotoLine = function(line, endLine) {
    if (viewer && state.mode === "code" && !docPending) viewer.gotoLine(line, endLine);
    else window.pendingCodeLine = { line, endLine };
  };
  function postCode(action, fields) {
    sendToSwift("code", Object.assign({ action }, fields || {}));
  }
  const levelColors = {
    recent: "#2b54d9",
    months: "#2fa37a",
    years: "#d9982b",
    old: "#8a9199",
    critical: "#d9534f",
    high: "#d9982b",
    normal: "#5a8bd6",
    low: "#8a9199",
    // Relevance runs cold → hot in distinct hues, so each level reads at a glance.
    strong: "#e0457b",
    moderate: "#e2a93b",
    weak: "#3fb8d0",
    none: "transparent",
    // Pull request lens: what the change did to each part.
    added: "#2ea043",
    changed: "#d29922",
    removed: "#e5534b",
    moved: "#58a6ff"
  };
  const levelMarks = {
    critical: "rgba(217, 83, 79, .17)",
    high: "rgba(217, 152, 43, .13)",
    low: "dim",
    strong: "rgba(224, 69, 123, .18)",
    moderate: "rgba(226, 169, 59, .13)",
    weak: "rgba(63, 184, 208, .08)",
    none: "dim",
    recent: "rgba(43, 84, 217, .13)",
    months: "rgba(47, 163, 122, .09)",
    added: "rgba(46, 160, 67, .18)",
    removed: "rgba(229, 83, 75, .30)"
  };
  function renderBands() {
    bandsTrack.textContent = "";
    heat.querySelectorAll(".code-heat-seg").forEach(function(el) {
      el.remove();
    });
    const show = !notes.hidden && marked.some(function(m) {
      return levelMarks[m.level];
    });
    bands.hidden = heat.hidden = !show;
    main.classList.toggle("with-heat", show);
    if (!show) return;
    const editor = viewer && viewer.element ? viewer.element : main.querySelector(".cm-editor");
    if (editor) container.style.setProperty("--mv-code-bg", getComputedStyle(editor).backgroundColor);
    marked.forEach(function(m) {
      const mark = levelMarks[m.level];
      if (!mark) return;
      const band = document.createElement("div");
      band.className = "code-band" + (mark === "dim" ? " dim" : "");
      band.dataset.start = m.start;
      band.dataset.end = m.end;
      if (mark !== "dim") {
        band.style.background = mark;
        band.style.borderLeftColor = m.color || levelColors[m.level];
      }
      bandsTrack.appendChild(band);
      const seg = document.createElement("div");
      seg.className = "code-heat-seg";
      seg.dataset.start = m.start;
      seg.dataset.end = m.end;
      seg.style.background = mark === "dim" ? "var(--border-color)" : m.color || levelColors[m.level];
      seg.title = m.title + " \xB7 " + m.level + " (L" + m.start + "\u2013" + m.end + ")";
      heat.appendChild(seg);
    });
  }
  function layoutBands(geo, scroller) {
    if (bands.hidden || !scroller) return;
    const top = scroller.getBoundingClientRect().top - main.getBoundingClientRect().top;
    bands.style.top = heat.style.top = top + "px";
    bands.style.height = heat.style.height = scroller.clientHeight + "px";
    bandsTrack.style.transform = "translateY(" + -geo.scrollTop + "px)";
    bandsTrack.querySelectorAll(".code-band").forEach(function(band) {
      const y = geo.lineTop(+band.dataset.start);
      band.style.top = y + "px";
      band.style.height = Math.max(1, geo.lineBottom(+band.dataset.end) - y) + "px";
    });
    const h = scroller.clientHeight, total = Math.max(1, geo.height);
    heat.querySelectorAll(".code-heat-seg").forEach(function(seg) {
      const y = geo.lineTop(+seg.dataset.start) / total * h;
      seg.style.top = y + "px";
      seg.style.height = Math.max(2, geo.lineBottom(+seg.dataset.end) / total * h - y) + "px";
    });
    heatView.style.top = geo.scrollTop / geo.height * h + "px";
    heatView.style.height = Math.max(4, Math.min(1, h / geo.height) * h) + "px";
  }
  heat.addEventListener("click", function(e) {
    const scroller = scrollerEl();
    if (!viewer || !scroller) return;
    const seg = e.target.classList.contains("code-heat-seg") ? e.target : null;
    if (seg) {
      viewer.gotoLine(+seg.dataset.start, +seg.dataset.end);
      return;
    }
    const ratio = (e.clientY - heat.getBoundingClientRect().top) / heat.clientHeight;
    scroller.scrollTop = ratio * viewer.geometry().height - scroller.clientHeight / 2;
  });
  function currentRatings() {
    const exp = notesState && notesState.explanation;
    if (!exp || lens.value === "explain" || lens.value === "freshness") return null;
    return (exp.ratings || {})[lens.value] || null;
  }
  function needsRating() {
    return lens.value !== "explain" && lens.value !== "freshness" && lens.value !== "importance";
  }
  function ago(unix) {
    const days = Math.max(0, Math.round((Date.now() / 1e3 - unix) / 86400));
    if (days < 1) return "today";
    if (days < 45) return days + (days === 1 ? " day ago" : " days ago");
    if (days < 540) return Math.round(days / 30) + " months ago";
    return (days / 365).toFixed(1).replace(".0", "") + " years ago";
  }
  const FRESHNESS = [[0, "today", "#2b54d9"], [30, "1 mo", "#3f8fd0"], [180, "6 mo", "#2fa37a"], [730, "2 y", "#d9982b"], [1460, "4 y+", "#8a9199"]];
  function mixHex(a, b, t) {
    const x = [1, 3, 5].map(function(i) {
      return parseInt(a.slice(i, i + 2), 16);
    });
    const y = [1, 3, 5].map(function(i) {
      return parseInt(b.slice(i, i + 2), 16);
    });
    return "#" + x.map(function(v, i) {
      return Math.round(v + (y[i] - v) * Math.max(0, Math.min(1, t))).toString(16).padStart(2, "0");
    }).join("");
  }
  function freshnessColor(unix) {
    const days = Math.max(0, (Date.now() / 1e3 - unix) / 86400);
    for (let i = 0; i < FRESHNESS.length - 1; i++) {
      if (days <= FRESHNESS[i + 1][0]) return mixHex(FRESHNESS[i][2], FRESHNESS[i + 1][2], (days - FRESHNESS[i][0]) / (FRESHNESS[i + 1][0] - FRESHNESS[i][0]));
    }
    return FRESHNESS[FRESHNESS.length - 1][2];
  }
  function renderLegend() {
    legend.textContent = "";
    const filter = (notesState && notesState.filters || []).find(function(f) {
      return f.id === lens.value;
    });
    const stops = lens.value === "freshness" ? FRESHNESS : lens.value === "explain" || lens.value === "importance" ? ["low", "normal", "high", "critical"].map(function(l) {
      return [0, l, levelColors[l]];
    }) : filter ? filter.levels.slice().reverse().map(function(l) {
      return [0, l, levelColors[l] === "transparent" ? "#8a9199" : levelColors[l]];
    }) : null;
    legend.hidden = !stops || notes.hidden;
    if (!stops) return;
    const title = document.createElement("b");
    title.textContent = lens.value === "freshness" ? "Last change" : filter && filter.id !== "importance" ? "Relevance" : "Importance";
    legend.appendChild(title);
    stops.forEach(function(stop, i) {
      const label = document.createElement("span");
      label.textContent = stop[1];
      legend.appendChild(label);
      if (!stops[i + 1]) return;
      const seg = document.createElement("i");
      seg.style.background = "linear-gradient(to right, " + stop[2] + ", " + stops[i + 1][2] + ")";
      legend.appendChild(seg);
    });
  }
  function freshnessLevel(unix) {
    const days = (Date.now() / 1e3 - unix) / 86400;
    return days < 31 ? "recent" : days < 183 ? "months" : days < 730 ? "years" : "old";
  }
  function queueLayout() {
    if (layoutQueued) return;
    layoutQueued = true;
    requestAnimationFrame(function() {
      layoutQueued = false;
      layoutNotes();
    });
  }
  function layoutNotes() {
    if (!viewer || notes.hidden) return;
    const geo = viewer.geometry();
    const scroller = scrollerEl();
    layoutBands(geo, scroller);
    const offset = scroller ? scroller.getBoundingClientRect().top - viewport.getBoundingClientRect().top : 0;
    track.style.height = geo.height + "px";
    track.style.transform = "translateY(" + (offset - geo.scrollTop) + "px)";
    const cards = Array.from(track.querySelectorAll(".code-note"));
    const gap = codeSize < 8 ? 2 : 6;
    const visibleTop = geo.scrollTop - offset;
    const limit = visibleTop + viewport.clientHeight - 4;
    for (let pass = 0; pass < 2; pass++) {
      let bottom2 = visibleTop - gap;
      cards.forEach(function(card, i) {
        const top = Math.max(geo.lineTop(+card.dataset.start), bottom2 + gap);
        const next = cards[i + 1] ? geo.lineTop(+cards[i + 1].dataset.start) : Infinity;
        const room = next - top - gap;
        card.classList.remove("compact", "mini");
        if (pass === 1) {
          card.classList.add("mini");
        } else if (card.offsetHeight > room) {
          card.classList.add("compact");
          if (card.offsetHeight > room) {
            card.classList.remove("compact");
            card.classList.add("mini");
          }
        }
        card.style.top = top + "px";
        bottom2 = top + card.offsetHeight;
      });
      const wholeFileVisible = geo.height <= viewer.viewportHeight() * 1.05 + 16;
      if (!wholeFileVisible || bottom2 <= limit) break;
    }
    if (geo.height <= viewer.viewportHeight() * 1.05 + 16) {
      let ceiling = limit;
      for (let i = cards.length - 1; i >= 0; i--) {
        const h = cards[i].offsetHeight;
        const top = Math.min(parseFloat(cards[i].style.top), ceiling - h);
        cards[i].style.top = Math.max(visibleTop, top) + "px";
        ceiling = top - gap;
      }
    }
    let bottom = 0;
    cards.forEach(function(card) {
      const start = +card.dataset.start, end = +card.dataset.end;
      bottom = Math.max(bottom, parseFloat(card.style.top) + card.offsetHeight);
      const bar = card.previousElementSibling;
      if (bar && bar.classList.contains("code-note-span")) {
        bar.style.top = geo.lineTop(start) + "px";
        bar.style.height = Math.max(2, geo.lineBottom(end) - geo.lineTop(start)) + "px";
      }
    });
    track.style.height = Math.max(geo.height, bottom + 8) + "px";
  }
  window.setCodeBaseSize = function(size) {
    const factor = codeSize / baseSize;
    baseSize = size;
    setZoom(size * factor);
  };
  function setZoom(size) {
    codeSize = Math.min(28, Math.max(0.25, size));
    container.style.setProperty("--mv-code-size", codeSize + "px");
    container.classList.toggle("code-zoomed-out", codeSize < 8);
    zoomBar.querySelector(".code-zoom-level").textContent = Math.round(codeSize / baseSize * 100) + "%";
    if (viewer && viewer.setScale) viewer.setScale(codeSize / baseSize);
    else if (viewer) viewer.refresh();
    queueLayout();
  }
  function zoomToSection(start, end) {
    if (!viewer) return;
    if (viewer.kind === "markdown") {
      setZoom(baseSize);
      requestAnimationFrame(function() {
        viewer.gotoLine(start, end);
      });
      return;
    }
    const lines = end - start + 1;
    const fits = (viewer.viewportHeight() - 60) / (lines * 1.55);
    setZoom(Math.max(baseSize, Math.min(fits, baseSize * 1.6)));
    requestAnimationFrame(function() {
      requestAnimationFrame(function() {
        viewer.gotoLine(start, end);
        const geo = viewer.geometry();
        const scroller = scrollerEl();
        if (scroller) scroller.scrollTop = Math.max(0, geo.lineTop(start) - 24);
      });
    });
  }
  function fitWholeFile() {
    if (!viewer) return;
    if (viewer.fitScale) {
      setZoom(baseSize * viewer.fitScale(codeSize / baseSize));
      return;
    }
    setZoom((viewer.viewportHeight() - 20) / (viewer.lineCount() * 1.55));
  }
  zoomBar.addEventListener("click", function(e) {
    const z = e.target.getAttribute && e.target.getAttribute("data-z");
    if (z === "in") setZoom(codeSize * 1.25);
    else if (z === "out") setZoom(codeSize / 1.25);
    else if (z === "fit") fitWholeFile();
    else if (z === "reset") setZoom(baseSize);
  });
  main.addEventListener("wheel", function(e) {
    if (!e.ctrlKey) return;
    e.preventDefault();
    setZoom(codeSize * Math.exp(-e.deltaY * 0.01));
  }, { passive: false });
  function renderLensOptions() {
    const keep = lens.value || "explain";
    lens.textContent = "";
    const add = function(value, label) {
      const o = document.createElement("option");
      o.value = value;
      o.textContent = label;
      lens.appendChild(o);
    };
    add("explain", "Explanation");
    if (notesState && notesState.pr) add("pr", "\u2387 Pull request");
    if (notesState && notesState.search) add("search", "\u26A1 " + notesState.search.question.slice(0, 40));
    add("freshness", "Freshness");
    (notesState && notesState.filters || []).forEach(function(f) {
      add(f.id, f.name);
    });
    add("__new__", "\uFF0B New filter\u2026");
    lens.value = Array.from(lens.options).some(function(o) {
      return o.value === keep;
    }) ? keep : "explain";
  }
  let currentFile = null;
  let prFocusApplied = null;
  let prRequested = null;
  let searchFocusApplied = null;
  function renderNotes() {
    const st = notesState || {};
    const exp = st.explanation;
    if (st.pr && st.pr.focus && prFocusApplied !== currentFile) {
      prFocusApplied = currentFile;
      notesHidden = false;
      renderLensOptions();
      lens.value = "pr";
    }
    if (st.search && st.search.focus && searchFocusApplied !== currentFile) {
      searchFocusApplied = currentFile;
      notesHidden = false;
      renderLensOptions();
      lens.value = "search";
    }
    if (lens.value === "search" && st.search) {
      renderSearchNotes(st);
      return;
    }
    if (lens.value === "pr" && st.pr) {
      renderPRNotes(st);
      return;
    }
    notes.hidden = notesHidden || !exp && !st.working && !st.error;
    explainButton.hidden = !notes.hidden;
    explainButton.textContent = exp ? "\u2726 Notes" : "\u2726 Explain";
    explainButton.title = exp ? "Show the notes for this file" : "Explain this file section by section (AI)";
    container.classList.toggle("with-notes", !notes.hidden);
    notesStatus.textContent = st.error ? st.error : st.working ? st.activity || "Working\u2026" : st.stale ? "File changed \u2014 explain again" : "";
    notesStatus.className = "code-notes-status" + (st.error ? " error" : st.working ? " working" : "");
    renderLensOptions();
    info.title = exp ? exp.summary : "";
    info.hidden = !exp;
    track.textContent = "";
    marked = [];
    if (!exp) {
      renderBands();
      renderLegend();
      return;
    }
    const ratings = currentRatings();
    const fresh = lens.value === "freshness" ? exp.freshness : null;
    if (lens.value === "freshness" && !fresh && !st.working) postCode("freshness");
    if (needsRating() && !ratings && !st.working) postCode("rate", { filter: lens.value });
    exp.sections.forEach(function(section) {
      const rating = ratings ? ratings["s" + section.startLine] : null;
      const changed = fresh ? fresh["s" + section.startLine] : null;
      const fromExplanation = lens.value === "explain" || lens.value === "importance" && !rating;
      const level = fromExplanation ? section.importance : lens.value === "freshness" ? changed ? freshnessLevel(changed) : null : rating ? rating.level : null;
      if (level) marked.push({
        start: section.startLine,
        end: section.endLine,
        level,
        title: section.title,
        color: changed ? freshnessColor(changed) : null
      });
      const color = changed ? freshnessColor(changed) : levelColors[level];
      const span = document.createElement("div");
      span.className = "code-note-span";
      span.style.background = color || "transparent";
      const card = document.createElement("div");
      card.className = "code-note";
      card.dataset.start = section.startLine;
      card.dataset.end = section.endLine;
      card.style.borderLeftColor = color || "var(--border-color)";
      if (rating && rating.provisional) {
        card.style.borderLeftStyle = "dashed";
        card.classList.add("provisional");
      }
      const head = document.createElement("div");
      head.className = "code-note-title";
      head.textContent = section.title;
      const meta = document.createElement("span");
      meta.className = "code-note-meta";
      meta.textContent = "L" + section.startLine + "\u2013" + section.endLine + (lens.value === "freshness" ? changed ? " \xB7 " + ago(changed) : "" : level ? " \xB7 " + (rating && rating.provisional ? "\u2248 " : "") + level : "");
      head.appendChild(meta);
      const body = document.createElement("div");
      body.className = "code-note-body";
      body.textContent = fromExplanation || lens.value === "freshness" ? section.explanation : rating ? rating.reason : st.working ? "Rating\u2026" : "";
      card.appendChild(head);
      card.appendChild(body);
      card.title = section.title + " (L" + section.startLine + "\u2013" + section.endLine + ")\n\n" + body.textContent;
      card.style.setProperty("--note-color", color || "var(--border-color)");
      card.onclick = function() {
        if (viewer) viewer.gotoLine(section.startLine, section.endLine);
      };
      card.ondblclick = function() {
        zoomToSection(section.startLine, section.endLine);
      };
      track.appendChild(span);
      track.appendChild(card);
    });
    renderBands();
    renderLegend();
    queueLayout();
  }
  function renderPRNotes(st) {
    const pr = st.pr;
    notes.hidden = notesHidden;
    explainButton.hidden = !notes.hidden;
    container.classList.toggle("with-notes", !notes.hidden);
    renderLensOptions();
    notesStatus.textContent = pr.explaining ? "Explaining the changes\u2026" : "";
    notesStatus.className = "code-notes-status" + (pr.explaining ? " working" : "");
    info.title = pr.summary || "";
    info.hidden = !pr.summary;
    const requestKey = currentFile + "|" + pr.diffKey;
    if (!pr.explained && !pr.explaining && prRequested !== requestKey) {
      prRequested = requestKey;
      postCode("explainPR");
    }
    track.textContent = "";
    marked = [];
    pr.added.forEach(function(r) {
      marked.push({ start: r[0], end: r[1], level: "added", title: "Added" });
    });
    pr.removed.forEach(function(r) {
      marked.push({ start: r[0], end: r[0], level: "removed", title: r[1] + (r[1] === 1 ? " line" : " lines") + " removed" });
    });
    if (pr.deletedLines) marked.push({ start: 1, end: pr.deletedLines, level: "removed", title: "Removed by this change" });
    pr.changes.forEach(function(change) {
      const color = levelColors[change.kind] || levelColors.changed;
      const span = document.createElement("div");
      span.className = "code-note-span";
      span.style.background = color;
      const card = document.createElement("div");
      card.className = "code-note";
      card.dataset.start = change.start;
      card.dataset.end = change.end;
      card.style.borderLeftColor = color;
      card.style.setProperty("--note-color", color);
      const head = document.createElement("div");
      head.className = "code-note-title";
      head.textContent = change.title;
      const meta = document.createElement("span");
      meta.className = "code-note-meta";
      meta.textContent = "L" + change.start + (change.end !== change.start ? "\u2013" + change.end : "") + (change.kind ? " \xB7 " + change.kind : "");
      head.appendChild(meta);
      const body = document.createElement("div");
      body.className = "code-note-body";
      body.textContent = change.why || (pr.explaining ? "Explaining\u2026" : "");
      card.appendChild(head);
      card.appendChild(body);
      if (change.diff && change.diff.length) {
        const diff = document.createElement("pre");
        diff.className = "code-note-diff";
        change.diff.forEach(function(line) {
          const row = document.createElement("div");
          row.className = line[0] === "+" ? "add" : line[0] === "-" ? "del" : "";
          row.textContent = line;
          diff.appendChild(row);
        });
        card.appendChild(diff);
      }
      card.title = change.title + "\n\n" + (change.why || "");
      card.onclick = function() {
        if (viewer) viewer.gotoLine(change.start, change.end);
      };
      card.ondblclick = function() {
        zoomToSection(change.start, change.end);
      };
      track.appendChild(span);
      track.appendChild(card);
    });
    renderBands();
    renderPRLegend(pr);
    queueLayout();
  }
  function renderSearchNotes(st) {
    const search = st.search;
    notes.hidden = notesHidden;
    explainButton.hidden = !notes.hidden;
    container.classList.toggle("with-notes", !notes.hidden);
    renderLensOptions();
    notesStatus.textContent = "";
    notesStatus.className = "code-notes-status";
    info.hidden = true;
    track.textContent = "";
    marked = [];
    const color = levelColors.strong;
    search.places.forEach(function(place) {
      marked.push({ start: place.start, end: place.end, level: "strong", title: place.title });
      const span = document.createElement("div");
      span.className = "code-note-span";
      span.style.background = color;
      const card = document.createElement("div");
      card.className = "code-note";
      card.dataset.start = place.start;
      card.dataset.end = place.end;
      card.style.borderLeftColor = color;
      card.style.setProperty("--note-color", color);
      const head = document.createElement("div");
      head.className = "code-note-title";
      head.textContent = place.title;
      const meta = document.createElement("span");
      meta.className = "code-note-meta";
      meta.textContent = "L" + place.start + (place.end !== place.start ? "\u2013" + place.end : "") + (place.step ? " \xB7 " + place.step : "");
      head.appendChild(meta);
      const body = document.createElement("div");
      body.className = "code-note-body";
      body.textContent = place.why || "";
      card.appendChild(head);
      card.appendChild(body);
      card.title = place.title + "\n\n" + (place.why || "");
      card.onclick = function() {
        if (viewer) viewer.gotoLine(place.start, place.end);
      };
      card.ondblclick = function() {
        zoomToSection(place.start, place.end);
      };
      track.appendChild(span);
      track.appendChild(card);
    });
    renderBands();
    legend.textContent = "";
    legend.hidden = notes.hidden;
    const title = document.createElement("b");
    title.textContent = "\u26A1 " + search.question;
    legend.appendChild(title);
    const counts = document.createElement("span");
    counts.textContent = " \xB7 " + search.places.length + (search.places.length === 1 ? " place" : " places") + " in this file";
    legend.appendChild(counts);
    queueLayout();
  }
  function renderPRLegend(pr) {
    legend.textContent = "";
    legend.hidden = notes.hidden;
    const title = document.createElement("b");
    title.textContent = pr.title;
    legend.appendChild(title);
    const counts = document.createElement("span");
    counts.textContent = " +" + pr.additions + " \u2212" + pr.deletions + " \xB7 " + pr.changes.length + (pr.changes.length === 1 ? " change" : " changes");
    legend.appendChild(counts);
    ["added", "changed", "removed"].forEach(function(kind) {
      const key = document.createElement("span");
      key.className = "code-legend-key";
      key.style.color = levelColors[kind];
      key.textContent = " \u25CF " + kind;
      legend.appendChild(key);
    });
    if (pr.summary) {
      const p = document.createElement("div");
      p.className = "code-pr-summary";
      p.textContent = pr.summary;
      legend.appendChild(p);
    }
    if (pr.deletedLines) {
      const gone = document.createElement("div");
      gone.className = "code-pr-summary code-pr-note";
      gone.textContent = "This change removes the file; it is shown as it was before.";
      legend.appendChild(gone);
    }
    if (pr.remapped || pr.reviewOutdated) {
      const note = document.createElement("div");
      note.className = "code-pr-summary code-pr-note";
      note.textContent = pr.remapped ? "The file differs from this version of the change: lines are matched by content; the change is being read again." : "The code changed after the review \u2014 Review again in the PR X-Ray.";
      legend.appendChild(note);
    }
  }
  const tempForm = notes.querySelector(".code-temp-filter");
  let pendingTemp = null;
  let lensBeforeTemp = "explain";
  tempForm.addEventListener("submit", function(e) {
    e.preventDefault();
    const text = tempForm.querySelector("input").value.trim();
    if (lens.value.indexOf("tmp-") !== 0) lensBeforeTemp = lens.value;
    pendingTemp = text || null;
    postCode("tempFilter", { criterion: text });
  });
  tempForm.querySelector("button").addEventListener("click", function() {
    tempForm.querySelector("input").value = "";
    pendingTemp = null;
    postCode("tempFilter", { criterion: "" });
  });
  window.setCodeNotes = function(payload) {
    notesState = payload || null;
    const temp = (notesState && notesState.filters || []).find(function(f) {
      return f.id.indexOf("tmp-") === 0;
    });
    tempForm.querySelector("button").hidden = !temp;
    if (temp && document.activeElement !== tempForm.querySelector("input")) tempForm.querySelector("input").value = temp.criterion;
    if (!temp && lens.value.indexOf("tmp-") === 0) {
      renderLensOptions();
      lens.value = lensBeforeTemp;
    }
    if (pendingTemp && temp && temp.criterion === pendingTemp) {
      pendingTemp = null;
      renderLensOptions();
      lens.value = temp.id;
    }
    if (pendingLens && notesState) {
      const made = (notesState.filters || []).find(function(f) {
        return f.criterion === pendingLens;
      });
      if (made) {
        pendingLens = null;
        renderLensOptions();
        lens.value = made.id;
      }
    }
    renderNotes();
  };
  documentButton.addEventListener("click", function() {
    postCode("notesView", { show: false });
  });
  docExplainButton.addEventListener("click", function() {
    notesHidden = false;
    window.explainCurrentFile();
  });
  explainButton.addEventListener("click", function() {
    notesHidden = false;
    if (lens.value === "pr") lens.value = "explain";
    if (notesState && notesState.explanation) renderNotes();
    else postCode("explain");
  });
  notes.querySelector(".code-notes-redo").addEventListener("click", function() {
    postCode("explain");
  });
  notes.querySelector(".code-notes-close").addEventListener("click", function() {
    notesHidden = true;
    renderNotes();
  });
  const newFilter = notes.querySelector(".code-new-filter");
  lens.addEventListener("change", function() {
    if (lens.value === "__new__") {
      lens.value = "explain";
      newFilter.hidden = false;
      newFilter.querySelector("input").focus();
      return;
    }
    renderNotes();
  });
  newFilter.addEventListener("submit", function(e) {
    e.preventDefault();
    const text = newFilter.querySelector("input").value.trim();
    if (!text) return;
    postCode("createFilter", { name: "", criterion: text });
    newFilter.querySelector("input").value = "";
    newFilter.hidden = true;
    pendingLens = text;
  });
  window.addEventListener("resize", queueLayout);
  const navBar = document.createElement("div");
  navBar.className = "code-nav";
  navBar.innerHTML = '<button data-nav="back" title="Back (\u2318[)" disabled>\u25C0</button><button data-nav="forward" title="Forward (\u2318])" disabled>\u25B6</button>';
  main.appendChild(navBar);
  const linkHover = document.createElement("div");
  linkHover.className = "code-link-hover";
  linkHover.hidden = true;
  document.body.appendChild(linkHover);
  let peek = null;
  let menu = null;
  function cmView() {
    return viewer && viewer === codeViewer && codeViewer && codeViewer.view && state.mode === "code" ? codeViewer.view : null;
  }
  function wordAtPoint(x, y) {
    const view = cmView();
    if (!view) return null;
    const pos = view.posAtCoords({ x, y }, false);
    if (pos == null) return null;
    return wordAtPos(view, pos);
  }
  function wordAtPos(view, pos) {
    const range = view.state.wordAt(pos);
    if (!range) return null;
    const name = view.state.sliceDoc(range.from, range.to);
    if (!/^[A-Za-z_$][\w$]*$/.test(name) || name.length < 2) return null;
    return { name, line: view.state.doc.lineAt(range.from).number, from: range.from, to: range.to };
  }
  function cursorLine() {
    const view = cmView();
    return view ? view.state.doc.lineAt(view.state.selection.main.head).number : 1;
  }
  function showLink(word) {
    const view = cmView();
    const a = word && view ? view.coordsAtPos(word.from) : null;
    const b = word && view ? view.coordsAtPos(word.to) : null;
    if (!a || !b) {
      linkHover.hidden = true;
      return;
    }
    linkHover.hidden = false;
    linkHover.style.left = a.left + "px";
    linkHover.style.top = a.bottom - 2 + "px";
    linkHover.style.width = Math.max(4, b.left - a.left) + "px";
  }
  main.addEventListener("mousemove", function(e) {
    if (!e.metaKey) {
      if (!linkHover.hidden) linkHover.hidden = true;
      main.classList.remove("code-linking");
      return;
    }
    const word = wordAtPoint(e.clientX, e.clientY);
    main.classList.toggle("code-linking", !!word);
    showLink(word);
  });
  main.addEventListener("mouseleave", function() {
    linkHover.hidden = true;
    main.classList.remove("code-linking");
  });
  document.addEventListener("keyup", function(e) {
    if (e.key === "Meta") {
      linkHover.hidden = true;
      main.classList.remove("code-linking");
    }
  });
  main.addEventListener("scroll", function() {
    linkHover.hidden = true;
  }, true);
  let peekAnchor = null;
  let navLine = null;
  function anchorAt(word) {
    navLine = word ? word.line : null;
    const view = cmView();
    peekAnchor = word && view ? view.coordsAtPos(word.from) : null;
  }
  function goToDefinition(word) {
    if (!word) return;
    anchorAt(word);
    postCode("navDefinition", { name: word.name, line: word.line });
  }
  function findUsages(word) {
    if (!word) return;
    anchorAt(word);
    postCode("navUsages", { name: word.name, line: word.line });
  }
  main.addEventListener("mousedown", function(e) {
    if (!e.metaKey || e.button !== 0) return;
    const word = wordAtPoint(e.clientX, e.clientY);
    if (!word) return;
    e.preventDefault();
    e.stopPropagation();
    linkHover.hidden = true;
    if (e.altKey) findUsages(word);
    else goToDefinition(word);
  }, true);
  navBar.addEventListener("click", function(e) {
    const nav = e.target.getAttribute && e.target.getAttribute("data-nav");
    if (nav === "back") postCode("navBack", { line: cursorLine() });
    if (nav === "forward") postCode("navForward", { line: cursorLine() });
  });
  container.addEventListener("keydown", function(e) {
    if (!container.classList.contains("visible")) return;
    const view = cmView();
    if (e.key === "Escape" && (peek || menu || aiPanel)) {
      closePeek();
      closeMenu();
      if (aiPanel && !aiPanel.contains(document.activeElement)) closeAI();
      return;
    }
    if (e.key === "F12" && view) {
      e.preventDefault();
      const word = wordAtPos(view, view.state.selection.main.head);
      if (e.shiftKey) findUsages(word);
      else goToDefinition(word);
    } else if (e.metaKey && (e.key === "[" || e.key === "]")) {
      e.preventDefault();
      postCode(e.key === "[" ? "navBack" : "navForward", { line: cursorLine() });
    }
  });
  function closePeek() {
    if (peek) {
      peek.remove();
      peek = null;
    }
  }
  function closeMenu() {
    if (menu) {
      menu.remove();
      menu = null;
    }
  }
  document.addEventListener("mousedown", function(e) {
    if (peek && !peek.contains(e.target)) closePeek();
    if (menu && !menu.contains(e.target)) closeMenu();
  });
  function markName(text, name) {
    const re = new RegExp("(^|[^\\w$])(" + name.replace(/\$/g, "\\$") + ")(?![\\w$])", "g");
    return window.mvKit.escapeHtml(text).replace(re, "$1<mark>$2</mark>");
  }
  function showPeek(event) {
    closePeek();
    closeMenu();
    const results = event.results || [];
    peek = document.createElement("div");
    peek.className = "code-peek";
    peek.tabIndex = -1;
    const defs = results.filter(function(r) {
      return r.kind !== "usage";
    }).length;
    const uses = results.length - defs;
    const title = event.type === "definitions" ? results.length + " definitions of " + event.name : uses + (uses === 1 ? " usage" : " usages") + " of " + event.name + (defs ? " \xB7 " + defs + (defs === 1 ? " definition" : " definitions") : "");
    peek.innerHTML = '<div class="code-peek-head"><b></b><span></span><button title="Close (Esc)">\u2715</button></div><div class="code-peek-list"></div>';
    peek.querySelector("b").textContent = title + (event.truncated ? " (first matches)" : "");
    peek.querySelector("span").textContent = event.note || "";
    peek.querySelector("button").onclick = closePeek;
    const list = peek.querySelector(".code-peek-list");
    if (!results.length) {
      const empty = document.createElement("div");
      empty.className = "code-peek-empty";
      empty.textContent = "Nothing found in the project.";
      list.appendChild(empty);
    }
    let lastPath = null;
    const rows = [];
    results.forEach(function(r) {
      if (r.path !== lastPath) {
        lastPath = r.path;
        const file = document.createElement("div");
        file.className = "code-peek-file";
        const count = results.filter(function(x) {
          return x.path === r.path;
        }).length;
        file.innerHTML = '<span class="name"></span><span class="dir"></span><span class="count"></span>';
        const slash = r.path.lastIndexOf("/");
        file.querySelector(".name").textContent = r.path.slice(slash + 1);
        file.querySelector(".dir").textContent = slash > 0 ? r.path.slice(0, slash) : "";
        file.querySelector(".count").textContent = count;
        file.title = r.path;
        list.appendChild(file);
      }
      const row = document.createElement("div");
      row.className = "code-peek-row " + r.kind;
      row.innerHTML = '<span class="ln"></span><span class="tx"></span>';
      row.querySelector(".ln").textContent = r.line;
      const tx = row.querySelector(".tx");
      if (r.kind !== "usage") {
        const kind = document.createElement("i");
        kind.textContent = r.kind;
        tx.appendChild(kind);
        tx.appendChild(document.createTextNode(" "));
      }
      tx.insertAdjacentHTML("beforeend", markName(r.text, event.name));
      row.title = r.path + ":" + r.line;
      row.onclick = function() {
        openResult(r);
      };
      list.appendChild(row);
      rows.push({ el: row, r });
    });
    const view = cmView();
    const at = peekAnchor || (view ? view.coordsAtPos(view.state.selection.main.head) : null);
    const box = main.getBoundingClientRect();
    peek.style.left = Math.max(box.left + 12, Math.min(at ? at.left - 40 : box.left + 60, box.right - 620)) + "px";
    const top = at ? at.bottom + 6 : box.top + 60;
    peek.style.top = (top + 320 > window.innerHeight ? Math.max(box.top + 8, window.innerHeight - 340) : top) + "px";
    document.body.appendChild(peek);
    let selected = 0;
    function select(i) {
      if (!rows.length) return;
      selected = (i + rows.length) % rows.length;
      rows.forEach(function(x, j) {
        x.el.classList.toggle("selected", j === selected);
      });
      rows[selected].el.scrollIntoView({ block: "nearest" });
    }
    select(0);
    peek.addEventListener("keydown", function(e) {
      if (e.key === "ArrowDown") {
        e.preventDefault();
        select(selected + 1);
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        select(selected - 1);
      } else if (e.key === "Enter" && rows[selected]) {
        e.preventDefault();
        openResult(rows[selected].r);
      } else if (e.key === "Escape") {
        e.preventDefault();
        closePeek();
      }
    });
    peek.focus();
  }
  function openResult(r) {
    closePeek();
    postCode("navOpen", { path: r.path, target: r.line, line: navLine || cursorLine() });
  }
  main.addEventListener("contextmenu", function(e) {
    const view = cmView();
    if (!view) return;
    e.preventDefault();
    closeMenu();
    closePeek();
    const word = wordAtPoint(e.clientX, e.clientY);
    const sel = view.state.selection.main;
    menu = document.createElement("div");
    menu.className = "code-menu";
    function item(label, key, action, disabled) {
      const el = document.createElement("button");
      el.innerHTML = "<span></span><kbd></kbd>";
      el.firstChild.textContent = label;
      el.lastChild.textContent = key || "";
      el.disabled = !!disabled;
      el.onclick = function() {
        closeMenu();
        action();
      };
      menu.appendChild(el);
    }
    const name = word ? "\u201C" + word.name + "\u201D" : "";
    item("Go to Definition " + name, "\u2318-click", function() {
      goToDefinition(word);
    }, !word);
    item("Find Usages " + name, "\u2325\u2318-click", function() {
      findUsages(word);
    }, !word);
    menu.appendChild(document.createElement("hr"));
    item("\u2726 Explain with AI \u2014 everything related " + name, "", function() {
      postCode("explainSymbol", { name: word.name, line: word.line });
    }, !word);
    item(sel.empty ? "\u2726 Ask AI about this line" : "\u2726 Ask AI about the selection", "", function() {
      openAI(selectionRange(e.clientY));
    });
    item("Back", "\u2318[", function() {
      postCode("navBack", { line: cursorLine() });
    }, navBar.firstChild.disabled);
    menu.style.left = Math.min(e.clientX, window.innerWidth - 260) + "px";
    menu.style.top = Math.min(e.clientY, window.innerHeight - 170) + "px";
    document.body.appendChild(menu);
  });
  const askButton = document.createElement("button");
  askButton.className = "code-ask-btn";
  askButton.textContent = "\u2726 Ask AI";
  askButton.title = "Ask the AI about the selected code";
  askButton.hidden = true;
  document.body.appendChild(askButton);
  let aiPanel = null;
  let ai = null;
  const aiMd = window.markdownit ? window.markdownit({ html: false, linkify: true, breaks: false }) : null;
  function selectionRange(y) {
    const view = cmView();
    if (!view) return null;
    const doc = view.state.doc;
    const sel = view.state.selection.main;
    let from = sel.from, to = sel.to;
    if (sel.empty) {
      const pos = y != null ? view.posAtCoords({ x: view.contentDOM.getBoundingClientRect().left + 40, y }, false) : null;
      const line = doc.lineAt(pos != null ? pos : sel.head);
      from = line.from;
      to = line.to;
    }
    const start = doc.lineAt(from).number, end = doc.lineAt(to).number;
    return { start, end, text: view.state.sliceDoc(from, to) };
  }
  function placeAskButton() {
    const view = cmView();
    if (!view || aiPanel) {
      askButton.hidden = true;
      return;
    }
    const sel = view.state.selection.main;
    if (sel.empty || view.state.sliceDoc(sel.from, sel.to).trim().length < 2) {
      askButton.hidden = true;
      return;
    }
    const at = view.coordsAtPos(sel.to) || view.coordsAtPos(sel.from);
    if (!at) {
      askButton.hidden = true;
      return;
    }
    const box = main.getBoundingClientRect();
    askButton.hidden = false;
    askButton.style.left = Math.min(at.right + 8, box.right - 110) + "px";
    askButton.style.top = Math.max(box.top + 4, Math.min(at.bottom + 4, box.bottom - 60)) + "px";
  }
  main.addEventListener("mouseup", function() {
    setTimeout(placeAskButton, 0);
  });
  main.addEventListener("keyup", function(e) {
    if (e.shiftKey || e.key === "Shift") placeAskButton();
  });
  main.addEventListener("scroll", function() {
    askButton.hidden = true;
  }, true);
  askButton.addEventListener("mousedown", function(e) {
    e.preventDefault();
  });
  askButton.addEventListener("click", function() {
    openAI(selectionRange());
  });
  function openAI(range) {
    if (!range || !range.text.trim()) return;
    askButton.hidden = true;
    closeAI();
    ai = { id: "ai-" + Date.now(), range, turns: [] };
    aiPanel = document.createElement("div");
    aiPanel.className = "code-ai";
    aiPanel.innerHTML = '<div class="code-ai-head"><b>\u2726 Ask AI</b><span class="code-ai-range"></span><button class="code-ai-close" title="Close">\u2715</button></div><pre class="code-ai-snippet"></pre><div class="code-ai-quick"><button data-q="Explain what this code does, step by step, and why.">Explain</button><button data-q="Review this code for bugs, edge cases and risks. For each problem: how it shows up and how to fix it.">Find bugs</button><button data-q="How could this code be simpler, clearer or faster? Show the improved version.">Improve</button><button data-q="Where and how is this code used in the project, and what depends on it?">Where used</button></div><div class="code-ai-log"></div><form class="code-ai-form"><textarea rows="2" placeholder="Ask about this code\u2026 (\u21B5 to send, \u21E7\u21B5 new line)"></textarea><button type="submit">Ask</button></form>';
    aiPanel.querySelector(".code-ai-range").textContent = "L" + range.start + (range.end !== range.start ? "\u2013" + range.end : "") + (currentFile ? " \xB7 " + currentFile : "");
    const lines = range.text.split("\n");
    aiPanel.querySelector(".code-ai-snippet").textContent = lines.slice(0, 6).join("\n") + (lines.length > 6 ? "\n\u2026" : "");
    aiPanel.querySelector(".code-ai-close").onclick = closeAI;
    aiPanel.querySelectorAll(".code-ai-quick button").forEach(function(b) {
      b.onclick = function() {
        askAI(b.getAttribute("data-q"), b.textContent);
      };
    });
    const form = aiPanel.querySelector(".code-ai-form");
    const input = form.querySelector("textarea");
    form.addEventListener("submit", function(e) {
      e.preventDefault();
      const q = input.value.trim();
      if (!q) return;
      input.value = "";
      askAI(q, q);
    });
    input.addEventListener("keydown", function(e) {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        form.requestSubmit();
      }
      if (e.key === "Escape") {
        e.preventDefault();
        closeAI();
      }
    });
    main.appendChild(aiPanel);
    input.focus();
  }
  function closeAI() {
    if (ai) {
      const last = ai.turns[ai.turns.length - 1];
      if (last && !last.done) postCode("askStop", { id: ai.id });
    }
    if (aiPanel) aiPanel.remove();
    aiPanel = null;
    ai = null;
  }
  function askAI(question, label) {
    if (!ai) return;
    const last = ai.turns[ai.turns.length - 1];
    if (last && !last.done) return;
    const history = ai.turns.filter(function(t) {
      return t.done && !t.error;
    }).map(function(t) {
      return { q: t.q, a: t.a };
    });
    ai.turns.push({ q: question, label, a: "", done: false, activity: "Thinking\u2026" });
    renderAI();
    postCode("askAI", {
      id: ai.id,
      question,
      text: ai.range.text,
      start: ai.range.start,
      end: ai.range.end,
      history
    });
  }
  function linkPlaces(el) {
    el.querySelectorAll("code").forEach(function(code) {
      const m = code.textContent.match(/^([\w./@\-\[\]]+\.[A-Za-z0-9]+):(\d+)(?:[-–](\d+))?$/);
      if (!m || code.closest("pre")) return;
      code.classList.add("code-ai-place");
      code.title = "Open " + m[1] + " at line " + m[2];
      code.onclick = function() {
        postCode("navOpen", { path: m[1], target: +m[2], line: cursorLine() });
      };
    });
  }
  function renderAI() {
    if (!aiPanel || !ai) return;
    const log = aiPanel.querySelector(".code-ai-log");
    log.textContent = "";
    ai.turns.forEach(function(turn, i) {
      const q = document.createElement("div");
      q.className = "code-ai-q";
      q.textContent = turn.label;
      const a = document.createElement("div");
      a.className = "code-ai-a markdown-body";
      if (turn.a) {
        if (aiMd) {
          const renderedAI = aiMd.render(turn.a);
          a.innerHTML = typeof window.sanitizeMarkdownHTML === "function" ? window.sanitizeMarkdownHTML(renderedAI) : '<pre class="sanitization-error">' + window.mvKit.escapeHtml(turn.a) + "</pre>";
        } else {
          a.innerHTML = window.mvKit.escapeHtml(turn.a).replace(/\n/g, "<br>");
        }
        linkPlaces(a);
      }
      if (!turn.done) {
        const status = document.createElement("div");
        status.className = "code-ai-status";
        status.innerHTML = '<span class="code-ai-dot"></span><span></span><button>Stop</button>';
        status.children[1].textContent = turn.activity || "Writing\u2026";
        status.querySelector("button").onclick = function() {
          postCode("askStop", { id: ai.id });
        };
        a.appendChild(status);
      } else if (turn.error || turn.stopped) {
        const status = document.createElement("div");
        status.className = "code-ai-status error";
        status.textContent = turn.error ? "Failed: " + turn.error : "Stopped.";
        a.appendChild(status);
      }
      log.appendChild(q);
      log.appendChild(a);
    });
    aiPanel.querySelectorAll(".code-ai-quick button, .code-ai-form button").forEach(function(b) {
      const last = ai.turns[ai.turns.length - 1];
      b.disabled = !!(last && !last.done);
    });
    log.scrollTop = log.scrollHeight;
  }
  function receiveAnswer(event) {
    if (!ai || event.id !== ai.id) return;
    const turn = ai.turns[ai.turns.length - 1];
    if (!turn) return;
    if (event.text !== void 0 && (event.text || event.done)) turn.a = event.text || turn.a;
    if (event.activity) turn.activity = event.activity;
    else if (event.text) turn.activity = "Writing\u2026";
    if (event.done) {
      turn.done = true;
      turn.error = event.error || null;
      turn.stopped = !!event.stopped;
    }
    renderAI();
  }
  window.onCodeNavEvent = function(event) {
    if (!event) return;
    if (event.type === "state") {
      navBar.querySelector('[data-nav="back"]').disabled = !event.back;
      navBar.querySelector('[data-nav="forward"]').disabled = !event.forward;
      navBar.classList.toggle("active", !!(event.back || event.forward));
    } else if (event.type === "definitions" || event.type === "usages") {
      showPeek(event);
    } else if (event.type === "answer") {
      receiveAnswer(event);
    }
  };
  window.closeCodeFloating = function() {
    closePeek();
    closeMenu();
    askButton.hidden = true;
    linkHover.hidden = true;
  };
  window.codeViewOpenSearch = function() {
    if (viewer) viewer.openSearch();
  };
  const origSetContent = window.setContent;
  window.setContent = function(markdown) {
    window.leaveCodeView();
    origSetContent(markdown);
  };
  const origSetStructured = window.setStructuredContent;
  window.setStructuredContent = function(content, fileType) {
    window.leaveCodeView();
    origSetStructured(content, fileType);
  };
  const origSetTheme = window.setTheme;
  window.setTheme = function(id, accent, definition) {
    origSetTheme(id, accent, definition);
    if (viewer) viewer.setTheme(isDark());
  };
})();
;
(function(A) {
  Object.assign(A, {
    ago,
    aiFilters,
    bookColor,
    bookImportance,
    bookText,
    buildElements,
    buildFullPRView,
    buildPRView,
    changeShown,
    codeOverview,
    currentFilter,
    currentView,
    descendantsFiles,
    expandedSet,
    fileKey,
    formatCount,
    hiddenTags,
    indexView,
    isAIFilter,
    isBook,
    isHidden,
    isSearch,
    isTransparent,
    kindLabel,
    levelColor,
    levelRank,
    loadLibraries,
    overlayApplies,
    overlayInfo,
    palette,
    post,
    prByNode,
    ratingOf,
    representative,
    scales,
    stateKey,
    undescribedChapters
  });
  const container = document.getElementById("arch-container");
  A.container = container;
  if (!container) return;
  A.ready = true;
  const el = {
    graph: document.getElementById("arch-graph"),
    details: document.getElementById("arch-details"),
    crumbs: document.getElementById("arch-crumbs"),
    status: document.getElementById("arch-status"),
    legend: document.getElementById("arch-legend"),
    views: container.querySelectorAll("[data-arch-view]"),
    overlay: document.getElementById("arch-overlay"),
    flagged: document.getElementById("arch-flagged"),
    hide: document.getElementById("arch-hide"),
    prSource: document.getElementById("arch-pr-source"),
    prOpen: document.getElementById("arch-pr-open"),
    analyzePR: document.getElementById("arch-analyze-pr"),
    prNumber: document.getElementById("arch-pr-number"),
    prMap: document.getElementById("arch-pr-map"),
    prDate: document.getElementById("arch-pr-date"),
    history: document.getElementById("arch-history"),
    historyDay: document.getElementById("arch-history-day"),
    historyList: document.getElementById("arch-history-list"),
    review: document.getElementById("arch-review"),
    analyze: document.getElementById("arch-analyze"),
    codeTrace: document.getElementById("arch-code-trace"),
    rescan: document.getElementById("arch-rescan"),
    fit: document.getElementById("arch-fit"),
    progress: document.getElementById("arch-progress"),
    detailsResizer: document.getElementById("arch-details-resizer"),
    tempFilter: document.getElementById("arch-temp-filter"),
    detailsToggle: document.getElementById("arch-details-toggle"),
    stop: document.getElementById("arch-stop"),
    empty: document.getElementById("arch-empty"),
    deploy: document.getElementById("arch-deploy"),
    deployPicker: document.getElementById("arch-deploy-picker")
  };
  A.el = el;
  const ui = {
    payload: null,
    view: "logical",
    codeQuestions: {},
    codeSequenceIndex: null,
    overlay: "none",
    onlyFlagged: false,
    hidden: /* @__PURE__ */ new Set(),
    codeHidden: /* @__PURE__ */ new Set(),
    codeFilterInitialized: false,
    ratingRequested: /* @__PURE__ */ new Set(),
    // parents whose children were sent for AI importance
    describeRequested: /* @__PURE__ */ new Set(),
    expanded: {
      code: /* @__PURE__ */ new Set(),
      logical: /* @__PURE__ */ new Set(),
      modules: /* @__PURE__ */ new Set(),
      deployment: /* @__PURE__ */ new Set(),
      docs: /* @__PURE__ */ new Set(),
      pr: /* @__PURE__ */ new Set(),
      "prfull:logical": /* @__PURE__ */ new Set(),
      "prfull:modules": /* @__PURE__ */ new Set()
    },
    focus: { code: null, logical: null, modules: null, deployment: null, docs: null, pr: null, "prfull:logical": null, "prfull:modules": null },
    prView: null,
    // the PR X-Ray's own view, built from the X-Ray and the change
    prTab: false,
    // this page is the PR X-Ray tab (payload mode "pr")
    prMap: "focused",
    // PR X-Ray map: 'focused' (the parts the change touches) or 'full' (the whole X-Ray, changes marked)
    prFull: null,
    // the full map's view: the X-Ray's own view plus the files the change removes or adds
    prExpandedFor: null,
    // change whose touched parts were opened on the full map
    historyOpen: false,
    // the date picker is shown (project X-Ray and PR X-Ray)
    flow: "RIGHT",
    // the direction the top level of the last connected graph was laid out in (BUG-111)
    selected: null,
    graphKey: null,
    // view + snapshot version the canvas was built from
    viewChosen: false,
    // the user picked a view (no automatic fallback to Structure)
    root: null,
    // root folder of the X-Ray shown (project or one of its folders)
    progress: null,
    // live analysis progress (setArchitectureProgress)
    operations: null
    // project-root operations only; folder X-Rays receive none
  };
  A.ui = ui;
  A.cy = null;
  A.flowToken = 0;
  let libs = null;
  function post(action, fields) {
    if (action === "openFile" && ui.payload && ui.payload.pr && (ui.view === "pr" || ui.prTab || ui.overlay === "pr")) {
      fields = Object.assign({ fromPR: true }, fields || {});
    }
    sendToSwift("arch", Object.assign({ action }, fields || {}));
  }
  function loadScript(src) {
    return new Promise(function(resolve, reject) {
      const s = document.createElement("script");
      s.src = src;
      s.onload = resolve;
      s.onerror = function() {
        reject(new Error(src + " failed to load"));
      };
      document.head.appendChild(s);
    });
  }
  function loadLibraries() {
    if (libs) return libs;
    libs = loadScript("vendor/js/cytoscape.min.js").then(function() {
      return loadScript("vendor/js/elk.bundled.js");
    }).then(function() {
      return loadScript("vendor/js/cytoscape-elk.js");
    }).then(function() {
      cytoscape.use(cytoscapeElk);
    }).catch(function(error) {
      libs = null;
      throw error;
    });
    return libs;
  }
  const isDark = function() {
    return document.documentElement.getAttribute("data-theme") === "dark";
  };
  function palette() {
    const t = MarkViewThemes.token, dark = isDark();
    return {
      bg: t("--arch-bg"),
      node: t("--arch-node"),
      box: t("--arch-box"),
      boxAlpha: dark ? 0.07 : 0.045,
      boxLine: t("--arch-box-line"),
      line: t("--arch-line"),
      text: t("--arch-text"),
      mute: t("--arch-mute"),
      accent: t("--arch-accent"),
      ok: t("--arch-ok"),
      warn: t("--arch-warn"),
      bad: t("--arch-bad"),
      info: t("--arch-info"),
      dim: dark ? 0.28 : 0.3
    };
  }
  const roleNames = {
    presentation: "Presentation",
    application: "Application",
    infrastructure: "Infrastructure",
    platform: "Shared platform",
    other: "Unclassified",
    ui: "UI",
    api: "API",
    domain: "Domain logic",
    data: "Data",
    infra: "Infrastructure",
    integration: "Integration",
    tooling: "Tooling",
    tests: "Tests",
    docs: "Docs",
    config: "Config",
    shared: "Shared",
    app: "App"
  };
  A.roleNames = roleNames;
  const roleColor = {
    presentation: "#6c8cff",
    application: "#b07cff",
    infrastructure: "#8a94a6",
    platform: "#5bb3a8",
    other: "#9aa3b2",
    ui: "#6c8cff",
    api: "#b07cff",
    domain: "#2fa37a",
    data: "#d9822b",
    infra: "#8a94a6",
    integration: "#b98ad6",
    tooling: "#8a94a6",
    tests: "#a0a7b1",
    docs: "#4aa3c4",
    config: "#a0a7b1",
    shared: "#5bb3a8",
    app: "#6c8cff"
  };
  A.roleColor = roleColor;
  function currentView() {
    const snap = ui.payload && ui.payload.snapshot;
    if (!snap) return null;
    if (ui.view === "pr") return ui.prView;
    const view = snap.views.find(function(v) {
      return v.id === ui.view;
    }) || null;
    return view && ui.prFull && ui.prFull.id === view.id ? ui.prFull : view;
  }
  function changeShown() {
    return ui.view === "pr" || ui.prTab || overlayApplies() && ui.overlay === "pr";
  }
  function prDependencyEdges(prefix) {
    const pr = ui.payload && ui.payload.pr;
    return (pr && pr.dependencies || []).map(function(d) {
      return { source: prefix + d.source, target: prefix + d.target, kind: d.change, weight: 1, label: d.change === "added" ? "new" : "removed" };
    });
  }
  function changeBase(snap) {
    const logical = snap.views.find(function(v) {
      return v.id === "logical";
    });
    const base = logical || snap.views.find(function(v) {
      return v.id === "modules";
    });
    if (!base) return null;
    return { view: base, logical: !!logical, prefix: logical ? "l:f:" : "m:" };
  }
  function changeExtras(snap, pr, base) {
    const byId = new Map(base.view.nodes.map(function(n) {
      return [n.id, n];
    }));
    const assigned = function(path) {
      for (let folder = path.split("/").slice(0, -1).join("/"); ; folder = folder.split("/").slice(0, -1).join("/")) {
        const a = (snap.overrides || {})[folder] || ((snap.assignments || {})[folder] || {}).component;
        if (a) return a;
        if (!folder) return null;
      }
    };
    const parentFor = function(path) {
      if (base.logical) {
        const comp = assigned(path);
        return comp && byId.has("l:c:" + comp) ? "l:c:" + comp : byId.has("l:") ? "l:" : null;
      }
      for (let folder = path.split("/").slice(0, -1).join("/"); folder; folder = folder.split("/").slice(0, -1).join("/")) {
        if (byId.has("m:" + folder)) return "m:" + folder;
      }
      return byId.has("m:") ? "m:" : null;
    };
    const extra = [];
    pr.files.forEach(function(f) {
      const id = base.prefix + f.path;
      if (byId.has(id)) return;
      extra.push({
        id,
        parent: parentFor(f.path),
        kind: "file",
        name: f.path.split("/").pop(),
        path: f.path,
        loc: f.deleted ? f.deletions : f.additions,
        files: 1,
        removed: !!f.deleted,
        summary: f.deleted ? "Removed in this change" : "New in this change"
      });
    });
    return extra;
  }
  function buildPRView(snap, pr) {
    if (!snap || !pr) return null;
    const base = changeBase(snap);
    if (!base) return null;
    const prefix = base.prefix;
    const byId = new Map(base.view.nodes.map(function(n) {
      return [n.id, n];
    }));
    const keep = /* @__PURE__ */ new Set();
    const changed = new Set(pr.files.map(function(f) {
      return prefix + f.path;
    }));
    (pr.dependencies || []).forEach(function(d) {
      changed.add(prefix + d.target);
    });
    changed.forEach(function(id) {
      for (let n = byId.get(id); n && !keep.has(n.id); n = n.parent != null ? byId.get(n.parent) : null) keep.add(n.id);
    });
    const extra = changeExtras(snap, pr, base);
    extra.forEach(function(node) {
      for (let n = node.parent != null ? byId.get(node.parent) : null; n && !keep.has(n.id); n = n.parent != null ? byId.get(n.parent) : null) keep.add(n.id);
      keep.add(node.id);
    });
    const nodes = base.view.nodes.filter(function(n) {
      return keep.has(n.id);
    }).concat(extra);
    const edges = base.view.edges.filter(function(e) {
      return keep.has(e.source) && keep.has(e.target) && changed.has(e.source) && changed.has(e.target);
    }).concat(prDependencyEdges(prefix).filter(function(e) {
      return keep.has(e.source) && keep.has(e.target);
    }));
    return { id: "pr", nodes, edges };
  }
  function buildFullPRView(snap, pr) {
    if (!snap) return null;
    const base = changeBase(snap);
    if (!base) return null;
    if (!pr) return base.view;
    return { id: base.view.id, nodes: base.view.nodes.concat(changeExtras(snap, pr, base)), edges: base.view.edges };
  }
  function indexView(view) {
    const byId = /* @__PURE__ */ new Map(), children = /* @__PURE__ */ new Map();
    view.nodes.forEach(function(n) {
      byId.set(n.id, n);
    });
    view.nodes.forEach(function(n) {
      const p = n.parent;
      if (p != null && byId.has(p)) {
        if (!children.has(p)) children.set(p, []);
        children.get(p).push(n.id);
      }
    });
    return { byId, children };
  }
  function isTransparent(node) {
    return node && node.kind === "root" && node.parent == null;
  }
  function representative(id, idx, expanded) {
    const path = [];
    let cur = idx.byId.get(id);
    while (cur) {
      path.unshift(cur);
      cur = cur.parent != null ? idx.byId.get(cur.parent) : null;
    }
    for (let i = 0; i < path.length; i++) {
      const n = path[i];
      if (isTransparent(n)) continue;
      if (!expanded.has(n.id) || !(idx.children.get(n.id) || []).length) return n.id;
    }
    return path.length ? path[path.length - 1].id : null;
  }
  function drawnNodes(idx, expanded) {
    const drawn = [];
    function visit(id) {
      const node = idx.byId.get(id);
      const kids = idx.children.get(id) || [];
      if (isTransparent(node)) {
        kids.forEach(visit);
        return;
      }
      drawn.push(node);
      if (expanded.has(id)) kids.forEach(visit);
    }
    idx.byId.forEach(function(n) {
      if (n.parent == null || !idx.byId.has(n.parent)) visit(n.id);
    });
    return drawn;
  }
  function descendantsFiles(id, idx, out) {
    const kids = idx.children.get(id) || [];
    const node = idx.byId.get(id);
    if (!kids.length || node && (node.kind === "file" || node.kind === "doc")) {
      out.push(id);
      return out;
    }
    kids.forEach(function(k) {
      descendantsFiles(k, idx, out);
    });
    return out;
  }
  function fileKey(node) {
    return node && node.path != null ? "m:" + node.path : null;
  }
  const codeViews = { code: 1, modules: 1, logical: 1, pr: 1 };
  A.codeViews = codeViews;
  function isBook() {
    return ui.view === "docs";
  }
  const bookKinds = { root: "book", dir: "part", doc: "chapter", entity: "item" };
  function kindLabel(node) {
    if (isBook() && bookKinds[node.kind]) return bookKinds[node.kind];
    return node.kind === "moduleRef" ? "module" : node.kind;
  }
  function firstSentence(text, max) {
    const m = /^[\s\S]*?[.!?](?=\s|$)/.exec(text || "");
    let out = (m ? m[0] : text || "").replace(/\s+/g, " ").trim();
    if (out.length > max) out = out.slice(0, max - 1).replace(/\s+\S*$/, "") + "\u2026";
    return out;
  }
  function undescribedChapters(view) {
    return view.nodes.filter(function(n) {
      return n.kind === "doc" && !n.summarySignature;
    });
  }
  function bookIndex() {
    const snap = ui.payload && ui.payload.snapshot;
    if (!snap) return null;
    if (ui.bookIndexFor === snap) return ui.bookIndex;
    const book = snap.views.find(function(v) {
      return v.id === "docs";
    });
    const index = { chapters: /* @__PURE__ */ new Map(), sections: /* @__PURE__ */ new Map() };
    (book ? book.nodes : []).forEach(function(n) {
      if (n.kind === "doc" && n.path) index.chapters.set(n.path, n);
      else if (n.kind === "section" && n.path && n.line) index.sections.set(n.path + ":" + n.line, n);
    });
    ui.bookIndexFor = snap;
    ui.bookIndex = index;
    return index;
  }
  function nodeDescription(node) {
    if (!node || node.kind === "change" || node.kind === "changePart" || ui.view === "code" && node.kind === "layer") return null;
    const book = bookText(node);
    const text = node.summary || book && book.summary;
    if (!text) return null;
    let out = String(text).replace(/\s+/g, " ").trim();
    if (out.length > 240) out = out.slice(0, 239).replace(/\s+\S*$/, "") + "\u2026";
    return out || null;
  }
  function bookText(node) {
    if (isBook() || !node || !node.path) return null;
    const index = bookIndex();
    if (!index) return null;
    if (node.kind === "file" || node.kind === "doc") return index.chapters.get(node.path) || null;
    if (node.kind === "entity" && node.line) return index.sections.get(node.path + ":" + node.line) || null;
    return null;
  }
  function overlayApplies() {
    if (ui.overlay === "none") return false;
    if (ui.view === "deployment") return isSearch(currentFilter());
    if (codeViews[ui.view]) return true;
    return ui.view === "docs" && (isAIFilter() || ui.overlay === "size" || ui.overlay === "freshness");
  }
  const IMPORTANCE = { id: "importance", name: "Importance", levels: ["critical", "high", "normal", "low"] };
  A.IMPORTANCE = IMPORTANCE;
  function aiFilters() {
    return [IMPORTANCE].concat(ui.payload && ui.payload.filters || []);
  }
  function isAIFilter() {
    return ui.overlay.indexOf("ai:") === 0;
  }
  function currentFilter() {
    if (!isAIFilter()) return null;
    const id = ui.overlay.slice(3);
    return aiFilters().find(function(f) {
      return f.id === id;
    }) || null;
  }
  function levelRank(filter, level) {
    const i = filter.levels.indexOf(level);
    return i < 0 ? -1 : filter.levels.length - 1 - i;
  }
  function isSearch(filter) {
    return !!filter && filter.id.indexOf("tmp-") === 0;
  }
  function levelColor(filter, rank, c) {
    if (rank < 0) return null;
    const top = filter.levels.length - 1;
    if (isSearch(filter)) return rank === top ? "#e5484d" : null;
    if (filter.id === "importance") return [c.mute, c.info, c.warn, c.bad][rank];
    if (rank === 0) return null;
    const hot = ["#3fb8d0", "#e2a93b", "#e0457b"];
    return hot[Math.round((rank - 1) / Math.max(1, top - 1) * (hot.length - 1))];
  }
  function rgb(hex) {
    const h = hex.replace("#", "");
    return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
  }
  function mix(a, b, t) {
    const x = rgb(a), y = rgb(b);
    return "#" + x.map(function(v, i) {
      return Math.round(v + (y[i] - v) * Math.max(0, Math.min(1, t))).toString(16).padStart(2, "0");
    }).join("");
  }
  function scales(c) {
    return {
      complexity: {
        title: "Most complex function (McCabe)",
        note: "A folder shows its worst file",
        stops: [[1, "1", c.ok], [10, "10", c.ok], [15, "15", c.warn], [25, "25+", c.bad]]
      },
      bugs: {
        title: "Bug-fix commits in the worst file",
        note: "From git history",
        stops: [[0, "0", c.ok], [1, "1", c.ok], [3, "3", c.warn], [8, "8+", c.bad]]
      },
      tests: {
        title: "Tested share of source files",
        note: "Line coverage when a report exists",
        stops: [[0, "0%", c.bad], [35, "35%", c.warn], [70, "70%", c.ok], [100, "100%", c.ok]]
      },
      coverage: {
        title: "Documented share",
        note: "Docs older than the code count half",
        stops: [[0, "0%", c.bad], [35, "35%", c.warn], [70, "70%", c.ok], [100, "100%", c.ok]]
      },
      freshness: {
        title: "Last change",
        note: "Newest file in a folder",
        stops: [[0, "today", c.accent], [30, "1 mo", c.info], [180, "6 mo", c.ok], [730, "2 y", c.warn], [1460, "4 y+", c.mute]]
      }
    };
  }
  function scaleColor(scale, value) {
    const st = scale.stops;
    if (value <= st[0][0]) return st[0][2];
    for (let i = 0; i < st.length - 1; i++) {
      if (value <= st[i + 1][0]) return mix(st[i][2], st[i + 1][2], (value - st[i][0]) / (st[i + 1][0] - st[i][0]));
    }
    return st[st.length - 1][2];
  }
  function tagsOf(node, idx) {
    let cur = node;
    while (cur) {
      if (cur.tags && cur.tags.length) return cur.tags;
      cur = cur.parent != null ? idx.byId.get(cur.parent) : null;
    }
    return [];
  }
  const noTags = /* @__PURE__ */ new Set();
  function hiddenTags() {
    return ui.view === "code" ? ui.codeHidden : ui.prTab ? noTags : ui.hidden;
  }
  function isHidden(node, idx) {
    const hidden = hiddenTags();
    if (!hidden.size || node.kind === "root") return false;
    if (tagsOf(node, idx).some(function(t) {
      return hidden.has(t);
    })) return true;
    const kids = idx.children.get(node.id) || [];
    if (!kids.length) return false;
    const files = descendantsFiles(node.id, idx, []).map(function(id) {
      return idx.byId.get(id);
    }).filter(function(n) {
      return n && (n.kind === "file" || n.kind === "doc");
    });
    return files.length > 0 && files.every(function(f) {
      return tagsOf(f, idx).some(function(t) {
        return hidden.has(t);
      });
    });
  }
  function importanceKey(node) {
    if (!node) return null;
    if (node.kind === "component") return "c:" + node.id.replace(/^l:c:/, "");
    if (node.kind === "section") return node.id;
    if (["collection", "group", "entity", "change", "changePart"].indexOf(node.kind) >= 0) return null;
    if (node.path != null && node.kind !== "root") return "p:" + node.path;
    return null;
  }
  function bookImportance(node, idx) {
    if (!isBook() || ui.overlay !== "none" || !node) return null;
    const table = (ui.payload.snapshot && ui.payload.snapshot.ratings || {}).importance || {};
    function own(n) {
      const key = importanceKey(n);
      const r = key ? table[key] : null;
      return r ? levelRank(IMPORTANCE, r.level) : -1;
    }
    let best = own(node);
    if (best < 0) {
      (function walk(id) {
        (idx.children.get(id) || []).forEach(function(k) {
          const r = own(idx.byId.get(k));
          if (r > best) best = r;
          if (best < IMPORTANCE.levels.length - 1) walk(k);
        });
      })(node.id);
    }
    return best < 0 ? null : best;
  }
  function bookColor(rank, c) {
    return rank == null ? null : [c.mute, c.info, c.warn, c.bad][rank];
  }
  function ratingOf(node) {
    const filter = currentFilter();
    if (!filter) return null;
    const all = ui.payload.snapshot && ui.payload.snapshot.ratings || {};
    const table = all[filter.id] || {};
    if (ui.view === "deployment" && node) {
      if (node.kind !== "moduleRef") return table["dep:" + node.id.replace(/^p:/, "")] || null;
      const base = node.path || "";
      const hit = Object.keys(table).find(function(k) {
        return k.indexOf("p:") === 0 && table[k].level === "strong" && (k === "p:" + base || k.indexOf("p:" + base + "/") === 0);
      });
      return hit ? { level: "strong", reason: "Runs " + hit.slice(2), provisional: !!table[hit].provisional } : null;
    }
    const key = importanceKey(node);
    return key ? table[key] : null;
  }
  function requestRatings(idx, drawn) {
    const filter = currentFilter();
    if (!filter) return;
    if (filter.id !== "importance") {
      const all = ui.payload.snapshot && ui.payload.snapshot.ratings || {};
      const key = "search|" + filter.id;
      if (!all[filter.id] && !ui.ratingRequested.has(key)) {
        ui.ratingRequested.add(key);
        post("filterSearch", { filter: filter.id });
      }
      return;
    }
    const parents = /* @__PURE__ */ new Set();
    drawn.forEach(function(n) {
      if (n.parent != null) parents.add(n.parent);
    });
    parents.forEach(function(parentId) {
      const key = filter.id + "|" + ui.view + "|" + parentId;
      if (ui.ratingRequested.has(key)) return;
      const kids = (idx.children.get(parentId) || []).map(function(id) {
        return idx.byId.get(id);
      }).filter(function(n) {
        return n && importanceKey(n);
      });
      if (!kids.length || kids.every(function(n) {
        return ratingOf(n);
      })) return;
      ui.ratingRequested.add(key);
      post("rateImportance", { view: ui.view, parent: parentId, filter: filter.id });
    });
  }
  let prByNodeFor = null, prByNodeMap = /* @__PURE__ */ new Map();
  function prByNode() {
    const pr = ui.payload && ui.payload.pr;
    if (!pr) return /* @__PURE__ */ new Map();
    if (pr !== prByNodeFor) {
      prByNodeFor = pr;
      prByNodeMap = /* @__PURE__ */ new Map();
      pr.files.forEach(function(f) {
        prByNodeMap.set("m:" + f.path, f);
      });
    }
    return prByNodeMap;
  }
  const verdictRank = { bug: 3, concern: 2, ok: 1 };
  const COMPLEXITY = { moderate: 11, complex: 21 };
  const FIXES = { some: 2, many: 5 };
  function overlayInfo(node, idx) {
    if (!overlayApplies()) return null;
    if (["collection", "group", "entity", "change", "changePart"].indexOf(node.kind) >= 0) {
      let file = node;
      while (file && file.kind !== "file" && file.kind !== "doc") file = file.parent != null ? idx.byId.get(file.parent) : null;
      if (file) node = file;
    }
    const filter = currentFilter();
    if (filter) {
      const own = ratingOf(node);
      if (own) return { kind: "ai", filter, level: levelRank(filter, own.level), label: own.level, reason: own.reason, provisional: !!own.provisional };
      let best = -1, label = null, provisional = false;
      (function walk(id) {
        (idx.children.get(id) || []).forEach(function(k) {
          const r = ratingOf(idx.byId.get(k));
          if (r && levelRank(filter, r.level) > best) {
            best = levelRank(filter, r.level);
            label = r.level;
            provisional = !!r.provisional;
          }
          walk(k);
        });
      })(node.id);
      return { kind: "ai", filter, level: best, label, inherited: best >= 0, provisional };
    }
    const leaves = descendantsFiles(node.id, idx, []).map(function(id) {
      return idx.byId.get(id);
    }).filter(function(n) {
      return n && (n.kind === "file" || n.kind === "doc" || n.kind === "section");
    });
    const files = Array.from(new Set(leaves.map(fileKey)));
    const codeFiles = Array.from(new Set(leaves.filter(function(n) {
      return n.kind === "file" && n.language !== "markdown";
    }).map(fileKey)));
    if (ui.overlay === "coverage") {
      const cov = ui.payload.snapshot && ui.payload.snapshot.coverage || {};
      let fresh = 0, stale = 0, none = 0;
      codeFiles.forEach(function(id) {
        const c = cov[id];
        const s = c ? c.status : "none";
        if (s === "fresh") fresh++;
        else if (s === "stale") stale++;
        else none++;
      });
      const total = fresh + stale + none;
      return {
        kind: "coverage",
        fresh,
        stale,
        none,
        total,
        ratio: total ? (fresh + stale) / total : 0
      };
    }
    if (ui.overlay === "pr") {
      const pr = prByNode();
      let changed = 0, adds = 0, dels = 0, worst = 0, unreviewed = 0, findings = 0;
      files.forEach(function(id) {
        const f = pr.get(id);
        if (!f) return;
        changed++;
        adds += f.additions;
        dels += f.deletions;
        findings += (f.findings || []).length;
        if (f.verdict) worst = Math.max(worst, verdictRank[f.verdict] || 0);
        else unreviewed++;
      });
      return { kind: "pr", changed, adds, dels, worst, unreviewed, findings };
    }
    const metrics = ui.payload.snapshot && ui.payload.snapshot.metrics || {};
    const list = files.map(function(id) {
      return metrics[id];
    }).filter(Boolean);
    const codeList = codeFiles.map(function(id) {
      return metrics[id];
    }).filter(Boolean);
    if (ui.overlay === "tests") {
      const sources = codeList.filter(function(m) {
        return !m.isTest;
      });
      const tested = sources.filter(function(m) {
        return m.tested;
      }).length;
      const withCoverage = sources.filter(function(m) {
        return m.lineCoverage != null;
      });
      const lines = withCoverage.reduce(function(a, m) {
        return a + m.loc;
      }, 0);
      const covered = withCoverage.reduce(function(a, m) {
        return a + m.loc * m.lineCoverage;
      }, 0);
      return {
        kind: "tests",
        sources: sources.length,
        tested,
        tests: codeList.length - sources.length,
        lineCoverage: lines ? covered / lines : null,
        ratio: sources.length ? tested / sources.length : 0
      };
    }
    if (ui.overlay === "bugs") {
      const fixes = list.reduce(function(a, m) {
        return a + m.bugfixes;
      }, 0);
      const commits = list.reduce(function(a, m) {
        return a + m.commits;
      }, 0);
      let worst = 0, worstFile = null;
      files.forEach(function(id) {
        const m = metrics[id];
        if (m && m.bugfixes > worst) {
          worst = m.bugfixes;
          worstFile = id;
        }
      });
      return {
        kind: "bugs",
        fixes,
        commits,
        files: list.length,
        worst,
        worstName: worstFile ? worstFile.split("/").pop() : null
      };
    }
    if (ui.overlay === "freshness") {
      const ages = list.map(function(m) {
        return m.lastChanged;
      }).filter(function(t) {
        return t > 0;
      }).sort(function(a, b) {
        return a - b;
      });
      if (!ages.length) return { kind: "freshness", files: 0 };
      const now = Date.now() / 1e3, halfYear = 182 * 86400;
      return {
        kind: "freshness",
        files: ages.length,
        newest: ages[ages.length - 1],
        median: ages[Math.floor(ages.length / 2)],
        recentShare: ages.filter(function(t) {
          return now - t < halfYear;
        }).length / ages.length
      };
    }
    if (ui.overlay === "complexity" || ui.overlay === "size") {
      let worst = 0, worstName = null, complexFns = 0, fns = 0;
      const measured = ui.overlay === "complexity" ? codeList : list;
      measured.forEach(function(m) {
        fns += m.functions || 0;
        complexFns += m.complexFunctions || 0;
        if ((m.maxFunctionComplexity || 0) > worst) {
          worst = m.maxFunctionComplexity;
          worstName = m.maxFunctionName;
        }
      });
      const loc = measured.reduce(function(a, m) {
        return a + m.loc;
      }, 0);
      return {
        kind: ui.overlay,
        worst,
        worstName,
        complexFns,
        functions: fns,
        loc,
        files: measured.length
      };
    }
    return null;
  }
  function changeFacts(node, idx) {
    const pr = ui.payload && ui.payload.pr;
    if (!pr || !changeShown()) return null;
    if (["collection", "group", "entity", "change", "changePart"].indexOf(node.kind) >= 0) return null;
    const byPath = prByNode();
    let changed = 0, adds = 0, dels = 0;
    const seen = /* @__PURE__ */ new Set();
    descendantsFiles(node.id, idx, []).forEach(function(id) {
      const key = fileKey(idx.byId.get(id));
      const f = key && !seen.has(key) ? byPath.get(key) : null;
      if (!f) return;
      seen.add(key);
      changed++;
      adds += f.additions;
      dels += f.deletions;
    });
    if (!changed) return null;
    const own = node.kind === "file" ? byPath.get(fileKey(node)) : null;
    return { changed, adds, dels, removed: !!(own && own.deleted) };
  }
  function overlayValue(info) {
    if (!info) return null;
    if (info.kind === "tests") return info.sources ? 100 * (info.lineCoverage != null ? info.lineCoverage : info.ratio) : null;
    if (info.kind === "bugs") return info.files ? info.worst : null;
    if (info.kind === "complexity") return info.files ? info.worst : null;
    if (info.kind === "freshness") return info.files ? (Date.now() / 1e3 - info.newest) / 86400 : null;
    if (info.kind === "coverage") return info.total ? 100 * (info.fresh + 0.5 * info.stale) / info.total : null;
    return null;
  }
  function overlayFlag(info) {
    if (!info) return false;
    if (info.kind === "ai") return isSearch(info.filter) ? info.level === info.filter.levels.length - 1 : info.level >= info.filter.levels.length - 2;
    if (info.kind === "pr") return info.worst >= 2;
    const v = overlayValue(info);
    if (v == null) return false;
    if (info.kind === "complexity") return v >= COMPLEXITY.moderate;
    if (info.kind === "bugs") return v >= FIXES.some;
    if (info.kind === "freshness") return v >= 183;
    return v < 70;
  }
  function overlayColor(info, c) {
    if (!info) return null;
    if (info.kind === "tests" && !info.sources) return info.tests ? c.info : null;
    if (info.kind === "size") return null;
    if (info.kind === "ai") return levelColor(info.filter, info.level, c);
    const scale = scales(c)[info.kind];
    if (scale) {
      const v = overlayValue(info);
      return v == null ? null : scaleColor(scale, v);
    }
    if (info.kind === "pr") {
      if (!info.changed) return null;
      if (info.worst === 3) return c.bad;
      if (info.worst === 2) return c.warn;
      if (info.worst === 1 && !info.unreviewed) return c.ok;
      return c.info;
    }
    return null;
  }
  function ago(unix) {
    const days = Math.max(0, Math.round((Date.now() / 1e3 - unix) / 86400));
    if (days < 1) return "today";
    if (days < 45) return days + (days === 1 ? " day ago" : " days ago");
    if (days < 540) return Math.round(days / 30) + " months ago";
    return (days / 365).toFixed(1).replace(".0", "") + " years ago";
  }
  function formatCount(n) {
    return n >= 1e3 ? (n / 1e3).toFixed(n >= 1e4 ? 0 : 1) + "k" : String(n);
  }
  function prImpact(node) {
    const a = (ui.view === "pr" || ui.prTab) && ui.overlay === "pr" && ui.payload.pr && ui.payload.pr.analysis;
    if (!a || node.kind !== "component") return null;
    const id = node.id.replace(/^l:c:/, "");
    return a.impact.find(function(i) {
      return i.component === id;
    }) || null;
  }
  function nodeLabel(node, info, isBox, facts) {
    let label = node.name || node.id;
    if (label.length > 40) label = label.slice(0, 38) + "\u2026";
    if (facts && facts.removed) label = "\u2715 " + label;
    if (ui.view === "code" && node.kind === "layer" && !isBox) {
      const first = (node.summary || "").split(" \xB7 ")[0];
      if (first) label += "\n" + (first.length > 48 ? first.slice(0, 46) + "\u2026" : first);
      if (node.files) label += "\n" + formatCount(node.files) + " files";
      return label;
    }
    const book = bookText(node);
    if (book && node.kind === "file" && book.name && book.name !== node.name && book.name + ".md" !== node.name) {
      label += "\n" + (book.name.length > 60 ? book.name.slice(0, 58) + "\u2026" : book.name);
    }
    const described = isBox ? null : nodeDescription(node);
    if (described) label += "\n" + described;
    const impact = prImpact(node);
    if (impact) label += "\nrisk: " + impact.risk;
    const meta = [];
    if (node.kind === "change") {
      meta.push((node.change ? node.change + " \xB7 " : "") + (node.endLine && node.endLine !== node.line ? "lines " + node.line + "\u2013" + node.endLine : "line " + node.line));
    } else if (node.kind === "changePart") {
      meta.push(node.files + (node.files === 1 ? " change" : " changes"));
    } else if (node.kind === "collection" || node.kind === "group") {
      if (node.files) meta.push(formatCount(node.files) + (node.files === 1 ? " item" : " items"));
    } else if (node.kind !== "file" && node.kind !== "doc" && node.kind !== "entity" && node.files) {
      meta.push(formatCount(node.files) + (isBook() && node.kind !== "section" ? " chapters" : " files"));
    }
    if (node.loc && !(isBook() && node.kind === "section")) meta.push(formatCount(node.loc) + " lines");
    if (node.tech) meta.push(node.tech);
    if (info && info.kind === "coverage" && info.total > 1) {
      meta.push(Math.round(info.ratio * 100) + "% documented" + (info.stale ? " \xB7 " + info.stale + " outdated" : ""));
    }
    const inside = ["collection", "group", "entity", "change", "changePart"].indexOf(node.kind) >= 0;
    if (info && info.kind === "pr" && info.changed && !inside) meta.push(facts && facts.removed ? "removed \u2212" + info.dels : "+" + info.adds + " \u2212" + info.dels);
    else if (facts && (!info || info.kind !== "pr")) meta.push(facts.removed ? "removed \u2212" + facts.dels : "+" + facts.adds + " \u2212" + facts.dels);
    if (info && info.kind === "tests" && info.sources) {
      meta.push(info.lineCoverage != null ? Math.round(info.lineCoverage * 100) + "% lines covered" : info.tested + "/" + info.sources + " tested");
    }
    if (info && info.kind === "bugs" && info.files) {
      meta.push(node.kind === "file" ? info.fixes + " bug-fix commits of " + info.commits : info.fixes ? "worst: " + info.worstName + " (" + info.worst + " fixes)" : "no bug fixes");
    }
    if (info && info.kind === "freshness" && info.files) meta.push("changed " + ago(info.newest));
    if (info && info.kind === "ai" && info.label) meta.push((info.inherited ? "contains " : "") + info.label);
    if (info && info.kind === "complexity" && info.files) {
      meta.push("max " + info.worst + (info.worstName ? " in " + info.worstName : "") + (node.kind !== "file" && info.complexFns ? " \xB7 " + info.complexFns + " complex fns" : ""));
    }
    if (meta.length) label += "\n" + meta.join(" \xB7 ");
    return label;
  }
  function sizeBase(drawn) {
    const locs = drawn.map(function(n) {
      return n.loc || 0;
    }).filter(function(v) {
      return v > 0;
    }).sort(function(a, b) {
      return a - b;
    });
    return locs.length ? locs[Math.floor(locs.length / 2)] : 1;
  }
  const bandRoles = ["presentation", "application", "domain", "data", "other"];
  A.bandRoles = bandRoles;
  const crossRoles = ["integration", "infrastructure", "platform", "tooling", "tests"];
  A.crossRoles = crossRoles;
  const bandPartsLimit = 18;
  function codeOverview() {
    return ui.view === "code" && !ui.expanded.code.size;
  }
  function stateKey() {
    return ui.prTab && ui.prFull ? "prfull:" + ui.view : ui.view;
  }
  function expandedSet(idx) {
    const expanded = ui.expanded[stateKey()];
    if (!codeOverview()) return expanded;
    const open = /* @__PURE__ */ new Set();
    idx.byId.forEach(function(n) {
      const kids = (idx.children.get(n.id) || []).length;
      if ((n.kind === "layer" || n.kind === "externalGroup") && kids && kids <= bandPartsLimit) open.add(n.id);
    });
    return open;
  }
  function buildElements() {
    const view = currentView();
    if (!view) return [];
    const idx = indexView(view);
    const expanded = expandedSet(idx);
    const drawn = drawnNodes(idx, expanded).filter(function(n) {
      return !isHidden(n, idx);
    });
    requestRatings(idx, drawn);
    const drawnIds = new Set(drawn.map(function(n) {
      return n.id;
    }));
    const c = palette();
    const elements = [];
    drawn.forEach(function(node) {
      const kids = idx.children.get(node.id) || [];
      const isBox = expanded.has(node.id) && kids.length > 0;
      const info = overlayInfo(node, idx);
      const facts = changeFacts(node, idx);
      const label = nodeLabel(node, info, isBox, facts);
      const longest = label.split("\n").reduce(function(m, l) {
        return Math.max(m, l.length);
      }, 0);
      const grow = ui.overlay === "size" && overlayApplies() && node.loc ? Math.min(3.2, Math.max(1, Math.sqrt(node.loc / Math.max(1, sizeBase(drawn))))) : 1;
      const parent = node.parent != null && drawnIds.has(node.parent) && expanded.has(node.parent) ? node.parent : void 0;
      const described = !isBox && !!nodeDescription(node);
      const perChar = described ? 5.4 : 6.6;
      const w = Math.min(described ? 340 : 260, Math.max(70, longest * perChar + 22)) * grow;
      const rows = label.split("\n").reduce(function(a, l) {
        return a + Math.max(1, Math.ceil(l.length * perChar / Math.max(40, w - 24)));
      }, 0);
      elements.push({ group: "nodes", data: {
        id: node.id,
        parent,
        label,
        kind: node.kind,
        role: node.role || "",
        w,
        tw: Math.max(40, w - 14),
        h: (rows > 2 ? 12 + (described ? 11 : 12) * rows : rows > 1 ? 38 : 26) * grow,
        fill: (prImpact(node) ? { high: c.bad, medium: c.warn, low: c.ok }[prImpact(node).risk] : null) || overlayColor(info, c) || bookColor(bookImportance(node, idx), c) || (node.role ? roleColor[node.role] : null) || "",
        // Without a change loaded there is nothing to tell apart: nothing is dimmed.
        dimmed: ui.overlay === "pr" && ui.payload.pr && info && !info.changed ? 1 : 0,
        // The change, whatever overlay colours the node: a halo (a container that is open shows it on its parts).
        changed: facts && !isBox ? 1 : 0,
        removed: facts && facts.removed ? 1 : 0,
        // Keyword match not yet confirmed by the AI: drawn dashed.
        provisional: info && info.kind === "ai" && info.provisional && info.level > 0 ? 1 : 0,
        // "Only flagged": the top two levels of an AI filter, else anything not green/neutral.
        flag: overlayFlag(info) ? 1 : 0,
        expandable: kids.length && !isBox ? 1 : 0
      }, classes: [
        node.kind,
        isBox ? "box" : "leaf",
        kids.length && !isBox ? "expandable" : "",
        described ? "described" : "",
        // Draft layers (REQ-004): guessed from file paths until the code analysis names components.
        ui.view === "code" && node.kind === "layer" && !A.codeModelOf(ui.payload.snapshot) ? "draft" : ""
      ].join(" ") });
    });
    if (ui.view === "code" && drawn.some(function(n) {
      return n.kind === "layer";
    })) {
      elements.push({ group: "nodes", data: {
        id: "code:actors",
        label: "Users",
        kind: "actors",
        w: 260,
        tw: 240,
        h: 30,
        fill: "",
        dimmed: 0,
        provisional: 0,
        flag: 0,
        expandable: 0
      }, classes: "actors leaf" });
    }
    const agg = /* @__PURE__ */ new Map();
    const prEdges = ui.view !== "pr" && (overlayApplies() && ui.overlay === "pr" || ui.prTab && ui.payload.pr && codeViews[ui.view]) ? prDependencyEdges(ui.view === "logical" ? "l:f:" : "m:") : [];
    view.edges.concat(prEdges).forEach(function(e) {
      if (!idx.byId.has(e.source) || !idx.byId.has(e.target)) return;
      const s = representative(e.source, idx, expanded), t = representative(e.target, idx, expanded);
      if (!s || !t || s === t || !drawnIds.has(s) || !drawnIds.has(t)) return;
      if (e.kind === "related") return;
      const key = s + "\u2192" + t + (e.kind === "added" || e.kind === "removed" ? "|" + e.kind : "");
      const cur = agg.get(key);
      if (cur) {
        cur.weight += e.weight || 1;
        if (!cur.label && e.label) cur.label = e.label;
        if (e.evidence && cur.evidence.indexOf(e.evidence) < 0 && cur.evidence.length < 20) cur.evidence.push(e.evidence);
      } else agg.set(key, { id: "e:" + key, source: s, target: t, weight: e.weight || 1, label: e.label || "", kind: e.kind, evidence: e.evidence ? [e.evidence] : [] });
    });
    agg.forEach(function(e) {
      elements.push({ group: "edges", data: e, classes: e.evidence.length ? "inference" : "" });
    });
    if (ui.onlyFlagged && !ui.prTab && overlayApplies() && ui.overlay !== "size") return keepFlagged(elements, c);
    return elements;
  }
  function keepFlagged(elements, c) {
    const nodes = elements.filter(function(e) {
      return e.group === "nodes";
    });
    const flagged = new Set(nodes.filter(function(e) {
      return e.classes.indexOf("box") < 0 && e.data.flag === 1;
    }).map(function(e) {
      return e.data.id;
    }));
    const parentOf = new Map(nodes.map(function(e) {
      return [e.data.id, e.data.parent];
    }));
    const keep = new Set(flagged);
    flagged.forEach(function(id) {
      let p = parentOf.get(id);
      while (p) {
        keep.add(p);
        p = parentOf.get(p);
      }
    });
    return elements.filter(function(e) {
      return e.group === "nodes" ? keep.has(e.data.id) : keep.has(e.data.source) && keep.has(e.data.target);
    });
  }
})(window.MVArchitecture = {});
;
(function(A) {
  if (!A.ready) return;
  const {
    bandRoles,
    buildElements,
    codeOverview,
    crossRoles,
    currentView,
    el,
    expandedSet,
    indexView,
    isBook,
    isHidden,
    palette,
    post,
    representative,
    stateKey,
    ui
  } = A;
  Object.assign(A, {
    activate,
    autoExpand,
    collapse,
    ensureCy,
    entityTarget,
    highlightNeighbourhood,
    openPRFile,
    render,
    renderEmpty,
    restyle,
    sectionTarget,
    stylesheet
  });
  function stylesheet() {
    const c = palette();
    return [
      { selector: "node", style: {
        "shape": "round-rectangle",
        "width": "data(w)",
        "height": "data(h)",
        "background-color": c.node,
        "border-width": 1,
        "border-color": c.line,
        "label": "data(label)",
        "color": c.text,
        "font-size": 10.5,
        "font-family": '-apple-system, "SF Pro Text", sans-serif',
        "text-valign": "center",
        "text-halign": "center",
        "text-wrap": "wrap",
        "text-max-width": "data(tw)",
        "line-height": 1.3
      } },
      { selector: 'node[fill != ""]', style: {
        "border-color": "data(fill)",
        "border-width": 2,
        "background-color": "data(fill)",
        "background-opacity": 0.14
      } },
      { selector: "node.expandable", style: { "border-style": "solid", "border-width": 1.5 } },
      { selector: "node.file, node.doc", style: { "font-size": 10, "font-family": '"SF Mono", Menlo, monospace' } },
      // A path has no spaces to wrap at. In the layered Code view its label breaks inside the word, so it stays in its
      // cell: a label wider than the cell widens the container around it (BUG-085).
      { selector: "node.fitLabel", style: { "text-overflow-wrap": "anywhere" } },
      { selector: "node.section", style: { "font-size": 10, "border-style": "dotted" } },
      // Contents of a file: collection → type → item.
      { selector: "node.collection", style: { "font-weight": 600, "border-style": "double", "border-width": 3 } },
      { selector: "node.group", style: { "font-size": 10, "border-style": "solid" } },
      { selector: "node.entity", style: { "font-size": 9.5, "border-style": "dotted", "text-max-width": 200 } },
      // Boxes that carry their description: smaller type, so the whole text is read in place.
      { selector: "node.described", style: { "font-size": 8.5, "line-height": 1.2, "text-max-width": "data(tw)" } },
      // What changed inside a file (PR X-Ray).
      { selector: "node.changePart", style: { "font-size": 10, "border-style": "solid" } },
      { selector: "node.change", style: { "font-size": 9.5, "border-color": "#d29922", "border-width": 1.5, "text-max-width": 220 } },
      { selector: "node.external, node.externalGroup", style: { "border-style": "dashed", "color": c.mute } },
      { selector: "node.moduleRef", style: { "border-style": "dotted" } },
      { selector: "node.box", style: {
        "shape": "round-rectangle",
        "background-color": c.box,
        "background-opacity": c.boxAlpha,
        "border-color": c.boxLine,
        "border-width": 1,
        "text-valign": "top",
        "text-halign": "center",
        "text-margin-y": -4,
        "font-weight": 600,
        "padding": 14,
        "color": c.mute
      } },
      // Containers keep a light fill; the overlay colour goes on the outline.
      { selector: 'node.box[fill != ""]', style: { "background-color": c.box, "background-opacity": c.boxAlpha, "border-color": "data(fill)", "border-width": 2 } },
      // Layered Code overview: a band wears the colour of its layer and names itself above.
      { selector: "node.layer.box", style: {
        "background-color": "data(fill)",
        "background-opacity": 0.08,
        "border-color": "data(fill)",
        "border-width": 1.5,
        "color": c.text,
        "font-size": 11.5,
        "text-margin-y": -6
      } },
      // Who the system serves: a caption above the stack, not a part of the model.
      { selector: "node.actors", style: {
        "background-opacity": 0,
        "border-style": "dashed",
        "border-color": c.mute,
        "color": c.mute,
        "font-weight": 600,
        "events": "no"
      } },
      { selector: "node[dimmed = 1]", style: { "opacity": c.dim } },
      // A change is marked whatever overlay colours the node: a halo behind a changed part, and a removed
      // file with a dashed red outline (its name carries a cross), so neither depends on the fill.
      { selector: "node[changed = 1]", style: {
        "underlay-color": c.info,
        "underlay-opacity": 0.3,
        "underlay-padding": 5,
        "underlay-shape": "round-rectangle",
        "underlay-corner-radius": 8
      } },
      { selector: "node[removed = 1]", style: {
        "border-style": "dashed",
        "border-color": c.bad,
        "border-width": 2,
        "underlay-color": c.bad,
        "underlay-opacity": 0.22
      } },
      // Replace Cytoscape's default selection fill (solid blue) with an accent outline.
      { selector: "node:selected", style: { "border-color": c.accent, "border-width": 2.5, "background-color": c.node, "background-opacity": 1 } },
      { selector: "node.box:selected", style: { "background-color": c.box, "background-opacity": c.boxAlpha, "border-color": c.accent } },
      { selector: 'node[fill != ""]:selected', style: { "background-color": "data(fill)", "background-opacity": 0.2 } },
      { selector: "node:active, edge:active", style: { "overlay-opacity": 0 } },
      { selector: "edge", style: {
        "width": "mapData(weight, 1, 20, 1, 3.5)",
        "line-color": c.line,
        "target-arrow-color": c.line,
        "target-arrow-shape": "triangle",
        "arrow-scale": 0.7,
        "curve-style": "bezier",
        "opacity": ui.view === "code" ? 0 : 0.85,
        "events": ui.view === "code" ? "no" : "yes"
      } },
      { selector: 'edge[label != ""]', style: {
        "label": "data(label)",
        "font-size": 9,
        "color": c.mute,
        "text-background-color": c.bg,
        "text-background-opacity": 1,
        "text-background-padding": 2
      } },
      { selector: "edge.faded", style: { "opacity": ui.view === "code" ? 0 : 0.12 } },
      { selector: "node.appearing", style: { "opacity": 0 } },
      // Links a pull request adds (green) or removes (red, dashed).
      { selector: 'edge[kind = "added"]', style: { "line-color": c.ok, "target-arrow-color": c.ok, "width": 2.5, "opacity": 1 } },
      { selector: 'edge[kind = "removed"]', style: { "line-color": c.bad, "target-arrow-color": c.bad, "width": 2.5, "line-style": "dashed", "opacity": 1 } },
      { selector: "node[provisional = 1]", style: { "border-style": "dashed" } },
      // Code view: draft layers dotted, AI-inferred dependencies dashed; scanner facts stay solid.
      { selector: "node.draft", style: { "border-style": "dotted" } },
      { selector: "edge.inference", style: { "line-style": "dashed" } },
      // Related sections the AI found in the Book: dashed, muted, their reason in the panel.
      { selector: 'edge[kind = "related"]', style: { "line-style": "dashed", "line-color": c.mute, "target-arrow-color": c.mute, "label": "", "opacity": 0.7 } },
      { selector: "edge.hot", style: { "line-color": c.accent, "target-arrow-color": c.accent, "opacity": 1, "events": "yes" } }
    ];
  }
  function layeredBands(keepView, fitTo) {
    const tops = A.cy.nodes().orphans().filter(function(n) {
      return n.data("kind") === "layer";
    });
    if (!tops.length) return false;
    const byRole = function(roles) {
      return roles.map(function(r) {
        return tops.filter(function(n) {
          return n.data("role") === r;
        }).toArray();
      }).reduce(function(a, b) {
        return a.concat(b);
      }, []);
    };
    const bands = byRole(bandRoles);
    const columns = byRole(crossRoles);
    const known = new Set(bands.concat(columns).map(function(n) {
      return n.id();
    }));
    tops.forEach(function(n) {
      if (!known.has(n.id())) bands.push(n);
    });
    if (!bands.length) return false;
    const gap = 50;
    const pad = 14;
    const cellGap = 12;
    const nest = 2.5;
    let closedOnly = false;
    const holdsOpened = function(kids) {
      return !closedOnly && kids.some(function(kid) {
        return kid.isParent();
      });
    };
    const colWidth = columns.length > 3 ? 144 : 168;
    const colGap = 24;
    const columnGridLimit = 4;
    const partHeight = function(kids, cellW) {
      return kids.reduce(function(m, kid) {
        const lines = String(kid.data("label") || "").split("\n").reduce(function(a, line) {
          return a + Math.max(1, Math.ceil(line.length * 6.2 / Math.max(40, cellW - 18)));
        }, 0);
        return Math.max(m, 14 + lines * 13);
      }, 40);
    };
    const fill = function(node, left, top, width, minHeight, gridCols) {
      const kids = node.children();
      if (!kids.length) {
        const h = Math.max(44, minHeight || 44);
        node.data({ w: width, h, tw: width - 24 }).addClass("fitLabel");
        node.position({ x: left + width / 2, y: top + h / 2 });
        return h;
      }
      if (holdsOpened(kids)) return fillOpened(node, kids, left, top, width, minHeight, gridCols);
      const inner = width - pad * 2;
      const fit = Math.max(1, Math.min(kids.length, gridCols || Math.floor((inner + cellGap) / 180)));
      const rows = Math.ceil(kids.length / fit);
      const cols = Math.ceil(kids.length / rows);
      const cellW = (inner - cellGap * (cols - 1)) / cols;
      const textH = partHeight(kids, cellW);
      const spread = minHeight ? (minHeight - pad * 2 - cellGap * (rows - 1)) / rows : 0;
      const cellH = rows > 1 ? Math.max(textH, Math.min(spread, 132)) : Math.max(textH, spread);
      const rowGap = rows > 1 && minHeight ? Math.max(cellGap, (minHeight - pad * 2 - rows * cellH) / (rows - 1)) : cellGap;
      kids.forEach(function(kid, i) {
        const r = Math.floor(i / cols), c = i % cols;
        const inRow = Math.min(cols, kids.length - r * cols);
        const rowW = (inner - cellGap * (inRow - 1)) / inRow;
        kid.data({ w: rowW, tw: Math.max(40, rowW - 16), h: cellH }).addClass("fitLabel");
        kid.position({
          x: left + pad + c * (rowW + cellGap) + rowW / 2,
          y: top + pad + r * (cellH + rowGap) + cellH / 2
        });
      });
      return Math.max(minHeight || 0, pad * 2 + rows * cellH + rowGap * (rows - 1));
    };
    const titleRoom = function(node, width) {
      const lines = String(node.data("label") || "").split("\n").reduce(function(a, line) {
        return a + Math.max(1, Math.ceil(line.length * 6.6 / Math.max(40, width - 24)));
      }, 0);
      return 2 + lines * 13.5;
    };
    const fillOpened = function(node, kids, left, top, width, minHeight, gridCols) {
      const inner = width - pad * 2;
      const closed = kids.filter(function(kid) {
        return !kid.isParent();
      }).toArray();
      const fit = Math.max(1, Math.min(closed.length || 1, gridCols || Math.floor((inner + cellGap) / 180)));
      const gridRows = closed.length ? Math.ceil(closed.length / fit) : 0;
      const cols = closed.length ? Math.ceil(closed.length / gridRows) : 1;
      const cellW = (inner - cellGap * (cols - 1)) / cols;
      const cellH = closed.length ? partHeight(closed, cellW) : 0;
      const opened = [];
      let seen = 0;
      kids.forEach(function(kid) {
        if (kid.isParent()) opened.push({ part: kid, after: seen ? Math.floor((seen - 1) / cols) : -1 });
        else seen++;
      });
      const sequence = [];
      const push = function(after) {
        opened.filter(function(o) {
          return o.after === after;
        }).forEach(function(o) {
          sequence.push({ part: o.part });
        });
      };
      push(-1);
      for (let r = 0; r < gridRows; r++) {
        sequence.push({ cells: closed.slice(r * cols, (r + 1) * cols) });
        push(r);
      }
      let y = top + pad;
      sequence.forEach(function(row) {
        if (row.cells) {
          const inRow = row.cells.length;
          const rowW = (inner - cellGap * (inRow - 1)) / inRow;
          row.cells.forEach(function(kid, c) {
            kid.data({ w: rowW, tw: Math.max(40, rowW - 16), h: cellH }).addClass("fitLabel");
            kid.position({ x: left + pad + c * (rowW + cellGap) + rowW / 2, y: y + cellH / 2 });
          });
          y += cellH + cellGap;
        } else {
          y += titleRoom(row.part, inner);
          row.part.data({ tw: Math.max(40, inner - 24) });
          y += nest;
          y += fill(row.part, left + pad + nest, y, inner - nest * 2, 0) + nest + cellGap;
        }
      });
      return Math.max(minHeight || 0, y - cellGap + pad - top);
    };
    const columnGrid = function(column, stackHeight) {
      const kids = column.children();
      const cell = colWidth - pad * 2;
      let cols = 1;
      for (let fit = 1; fit <= Math.min(columnGridLimit, kids.length); fit++) {
        const rows = Math.ceil(kids.length / fit);
        cols = Math.ceil(kids.length / rows);
        if (pad * 2 + rows * partHeight(kids, cell) + cellGap * (rows - 1) <= stackHeight) break;
      }
      if (holdsOpened(kids)) cols = Math.max(cols, 2);
      return { cols, width: pad * 2 + cols * cell + cellGap * (cols - 1) };
    };
    const place = function(bandWidth2) {
      let y = 0;
      bands.forEach(function(band) {
        y += fill(band, 0, y, bandWidth2, 0) + gap;
      });
      const stackHeight = Math.max(1, y - gap);
      let x = bandWidth2 + 48, height = stackHeight;
      columns.forEach(function(column) {
        const grid = columnGrid(column, stackHeight);
        height = Math.max(height, fill(column, x, 0, grid.width, stackHeight, grid.cols));
        x += grid.width + colGap;
      });
      return { height, cross: columns.length ? x - colGap - bandWidth2 : 0 };
    };
    let bandWidth = Math.max(560, Math.min(1120, columns.length ? 860 : 1e3));
    closedOnly = true;
    const first = place(bandWidth);
    const ratio = Math.max(0.6, A.cy.width() / Math.max(1, A.cy.height()));
    const wanted = Math.round(Math.max(520, Math.min(1200, ratio * first.height - first.cross)));
    if (Math.abs(wanted - bandWidth) > 40) bandWidth = wanted;
    closedOnly = false;
    const placed = place(bandWidth);
    const fullWidth = bandWidth + placed.cross;
    const actors = A.cy.getElementById("code:actors");
    if (actors.length) {
      actors.data({ w: fullWidth, tw: fullWidth - 24, h: 30 });
      actors.position({ x: fullWidth / 2, y: -(gap + 15) });
    }
    const external = A.cy.nodes().orphans().filter(function(n) {
      return n.data("kind") === "externalGroup";
    });
    external.forEach(function(group, i) {
      fill(group, 0, placed.height + gap + i * 80, fullWidth, 0);
    });
    const target = fitTo ? A.cy.getElementById(fitTo) : null;
    if (target && target.length) A.cy.fit(target.union(target.descendants()), 40);
    else if (!keepView) A.cy.fit(A.cy.nodes(), 28);
    return true;
  }
  function layout(fitTo, keepView) {
    if (!A.cy) return;
    const count = A.cy.nodes().length;
    if (ui.view === "code" && count && layeredBands(keepView, fitTo)) return;
    const flowLimit = 20;
    function sparse(children) {
      if (children.length > flowLimit) return true;
      const ids = new Set(children.map(function(n) {
        return n.id();
      }));
      const links = children.connectedEdges().filter(function(e) {
        return ids.has(e.source().id()) && ids.has(e.target().id());
      }).length;
      return links < 0.25 * children.length;
    }
    const topSparse = sparse(A.cy.nodes().orphans());
    const packed = function(ratio) {
      return {
        "elk.algorithm": "rectpacking",
        "elk.aspectRatio": String(ratio),
        "elk.spacing.nodeNode": 14,
        "elk.padding": "[top=30,left=14,bottom=14,right=14]"
      };
    };
    const layeredFor = function(direction) {
      return {
        "elk.algorithm": "layered",
        "elk.direction": direction,
        "elk.layered.spacing.nodeNodeBetweenLayers": 46,
        "elk.spacing.nodeNode": 18,
        "elk.padding": "[top=30,left=14,bottom=14,right=14]",
        "elk.layered.crossingMinimization.strategy": "LAYER_SWEEP",
        // Keep document order (sections, files) where edges allow it.
        "elk.layered.considerModelOrder.strategy": "NODES_AND_EDGES"
      };
    };
    const bands = ui.view === "code" && A.cy.nodes().every(function(n) {
      return n.data("kind") === "layer" || n.data("kind") === "externalGroup";
    });
    const layered = layeredFor(bands ? "DOWN" : "RIGHT");
    const options = function(direction) {
      return {
        name: "elk",
        nodeDimensionsIncludeLabels: false,
        elk: Object.assign(
          { "elk.hierarchyHandling": "SEPARATE_CHILDREN" },
          topSparse ? packed(Math.max(0.5, A.cy.width() / Math.max(1, A.cy.height()))) : direction ? layeredFor(direction) : layered
        ),
        nodeLayoutOptions: function(node) {
          if (!node.isParent()) return {};
          return sparse(node.children()) ? packed(1.6) : layered;
        }
      };
    };
    const run = function(direction) {
      A.cy.layout(Object.assign(options(direction), {
        fit: !fitTo && !keepView,
        padding: 28,
        animate: ui.view !== "code" && count < 200,
        animationDuration: 420,
        stop: function() {
          A.cy.nodes(".appearing").animate({ style: { opacity: 1 } }, { duration: 350, complete: function() {
            A.cy.nodes(".appearing").removeClass("appearing").removeStyle("opacity");
          } });
          if (fitTo) {
            const target = A.cy.getElementById(fitTo);
            if (target.length) {
              const elements = target.union(target.descendants()).union(target.neighborhood());
              if (ui.view === "code") A.cy.fit(elements, 40);
              else A.cy.animate({ fit: { eles: elements, padding: 40 }, duration: 260 });
            }
          }
        }
      })).run();
    };
    const choosing = !topSparse && !bands && ui.view !== "code" && !fitTo && !keepView && A.cy.nodes().orphans().length > 2 && count <= 150;
    if (!choosing) {
      run(bands ? void 0 : ui.flow);
      return;
    }
    const token = ++A.flowToken;
    const width = A.cy.width(), height = A.cy.height();
    const scaleOf = function(direction) {
      return new Promise(function(resolve) {
        let copy = null;
        try {
          copy = cytoscape({ headless: true, styleEnabled: true, style: A.cy.style().json(), elements: A.cy.elements().jsons() });
          const trial = copy.layout(Object.assign(options(direction), { fit: false, animate: false }));
          trial.one("layoutstop", function() {
            const box = copy.nodes().boundingBox({ includeLabels: false });
            copy.destroy();
            resolve(Math.min((width - 56) / Math.max(1, box.w), (height - 56) / Math.max(1, box.h)));
          });
          trial.run();
        } catch (e) {
          if (copy) copy.destroy();
          resolve(0);
        }
      });
    };
    scaleOf("RIGHT").then(function(right) {
      return scaleOf("DOWN").then(function(down) {
        return down > right * 1.15 ? "DOWN" : "RIGHT";
      });
    }).then(function(direction) {
      if (token !== A.flowToken || !A.cy) return;
      ui.flow = direction;
      run(direction);
    });
  }
  function renderEmpty() {
    const snap = ui.payload && ui.payload.snapshot;
    if (ui.view === "pr") {
      el.empty.hidden = !!ui.prView;
      el.empty.textContent = !snap ? "The X-Ray is still being built\u2026" : "Choose a pull request, your branch or your uncommitted changes above.";
      return;
    }
    const missing = snap && !snap.views.some(function(v) {
      return v.id === ui.view;
    });
    if (ui.view === "code" && currentView() && !currentView().nodes.some(function(n) {
      return n.kind === "file";
    })) {
      el.empty.hidden = false;
      el.empty.textContent = "No source code was found in this folder. Structure and Book show its other files.";
      return;
    }
    if (ui.view === "code" && currentView() && currentView().nodes.some(function(n) {
      return n.kind === "file";
    })) {
      const view = currentView(), idx = indexView(view);
      if (view.nodes.filter(function(n) {
        return n.kind === "file";
      }).every(function(n) {
        return isHidden(n, idx);
      })) {
        el.empty.hidden = false;
        el.empty.textContent = "All source code is hidden by the current filter. Choose Show all to see it.";
        return;
      }
    }
    const bookView = isBook() && !missing && currentView();
    if (bookView && !bookView.nodes.some(function(n) {
      return n.kind === "doc";
    })) {
      el.empty.hidden = false;
      el.empty.textContent = "No text documents in this folder.";
      return;
    }
    el.empty.hidden = !missing;
    if (!missing) return;
    const step = { logical: 2, deployment: 3 }[ui.view];
    const name = { logical: "Logical components", deployment: "The deployment map", docs: "The book" }[ui.view] || "This view";
    const p = ui.progress;
    el.empty.textContent = p && step ? name + " will appear after step " + step + " of " + p.steps + (p.step < step ? "." : " (running now).") + " Structure and the Book are available meanwhile." : step ? name + " is built by the AI analysis. Press Analyze to create it." : name + " is empty. Press Rescan.";
  }
  function render(fitTo) {
    renderEmpty();
    if (!A.cy) return;
    const previous = {};
    A.cy.nodes().forEach(function(n) {
      if (!n.isParent()) previous[n.id()] = Object.assign({}, n.position());
    });
    const hadNodes = Object.keys(previous).length > 0;
    A.cy.startBatch();
    A.cy.elements().remove();
    A.cy.add(buildElements());
    if (hadNodes) {
      A.cy.nodes().forEach(function(n) {
        if (n.isParent()) return;
        let at = previous[n.id()];
        for (let p = n.parent(); !at && p.length; p = p.parent()) at = previous[p.id()];
        if (at) n.position(at);
        if (!previous[n.id()] && ui.view !== "code") n.addClass("appearing");
      });
    }
    A.cy.style(stylesheet());
    A.cy.endBatch();
    if (ui.selected && A.cy.getElementById(ui.selected).length) A.cy.getElementById(ui.selected).select();
    if (ui.view === "code") highlightNeighbourhood(ui.selected ? A.cy.getElementById(ui.selected) : null);
    else showRelated(ui.selected);
    layout(fitTo);
    A.renderCrumbs();
    A.renderLegend();
    A.renderDetails();
  }
  function restyle() {
    if (!A.cy) return;
    const fresh = new Map(buildElements().filter(function(e) {
      return e.group === "nodes";
    }).map(function(e) {
      return [e.data.id, e.data];
    }));
    let resized = false;
    A.cy.batch(function() {
      A.cy.nodes().forEach(function(n) {
        const d = fresh.get(n.id());
        if (!d) return;
        if (n.data("w") !== d.w || n.data("h") !== d.h) resized = true;
        n.data({ label: d.label, fill: d.fill, dimmed: d.dimmed, changed: d.changed, removed: d.removed, w: d.w, h: d.h });
      });
      A.cy.style(stylesheet());
    });
    if (resized) layout(null, true);
    A.renderLegend();
    A.renderDetails();
  }
  function ensureCy() {
    if (A.cy) return;
    A.cy = cytoscape({
      container: el.graph,
      elements: [],
      style: stylesheet(),
      wheelSensitivity: 0.25,
      minZoom: 0.05,
      maxZoom: 3,
      boxSelectionEnabled: false
    });
    A.cy.on("tap", "node", function(evt) {
      ui.selectedEdge = null;
      ui.selected = evt.target.id();
      highlightNeighbourhood(evt.target);
      A.renderDetails();
      if (ui.view === "pr" || ui.prTab) {
        const shown = currentView();
        const node = shown && shown.nodes.find(function(n) {
          return n.id === evt.target.id();
        });
        const pr = ui.payload && ui.payload.pr;
        const inChange = ui.view === "pr" || pr && node && pr.files.some(function(f) {
          return f.path === node.path;
        });
        if (node && node.path && (node.kind === "file" || node.kind === "doc") && inChange) openPRFile(node.path);
      }
    });
    A.cy.on("tap", "edge", function(evt) {
      const e = evt.target;
      ui.selected = null;
      ui.selectedEdge = {
        view: ui.view,
        source: e.data("source"),
        target: e.data("target"),
        kind: e.data("kind") || "uses",
        label: e.data("label") || "",
        evidence: e.data("evidence") || []
      };
      A.cy.edges().removeClass("faded hot");
      A.cy.edges().not(e).addClass("faded");
      e.addClass("hot");
      A.renderDetails();
      if (ui.view !== "code" && ui.selectedEdge.kind !== "related") post("explainEdge", {
        view: ui.view,
        source: ui.selectedEdge.source,
        target: ui.selectedEdge.target,
        kind: ui.selectedEdge.kind,
        label: ui.selectedEdge.label || void 0
      });
    });
    A.cy.on("tap", function(evt) {
      if (evt.target === A.cy) {
        ui.selected = null;
        ui.selectedEdge = null;
        highlightNeighbourhood(null);
        A.renderDetails();
      }
    });
    A.cy.on("dbltap", "node", function(evt) {
      activate(evt.target.id());
    });
  }
  function showRelated(selectedId) {
    if (!A.cy) return;
    A.cy.remove(A.cy.edges(".related-live"));
    if (!isBook() || !selectedId) return;
    const view = currentView();
    if (!view) return;
    const idx = indexView(view);
    const expanded = ui.expanded[stateKey()];
    const seen = /* @__PURE__ */ new Set();
    const added = [];
    view.edges.forEach(function(e) {
      if (e.kind !== "related" || !idx.byId.has(e.source) || !idx.byId.has(e.target)) return;
      const s = representative(e.source, idx, expanded), t = representative(e.target, idx, expanded);
      if (!s || !t || s === t || s !== selectedId && t !== selectedId) return;
      if (!A.cy.getElementById(s).length || !A.cy.getElementById(t).length) return;
      const key = s + "\u2192" + t;
      if (seen.has(key)) return;
      seen.add(key);
      added.push({ group: "edges", data: { id: "rl:" + key, source: s, target: t, weight: e.weight || 1, label: "", kind: "related" }, classes: "related-live" });
    });
    if (added.length) A.cy.add(added);
  }
  function highlightNeighbourhood(node) {
    showRelated(node ? node.id() : null);
    A.cy.edges().removeClass("faded hot");
    if (!node) return;
    const connected = node.union(node.descendants()).connectedEdges();
    A.cy.edges().not(connected).addClass("faded");
    connected.addClass("hot");
  }
  function autoExpand(snap) {
    if (isBook()) {
      if (ui.userNavigated) return;
      const book = snap.views.find(function(v) {
        return v.id === "docs";
      });
      if (!book) return;
      const chapters = book.nodes.filter(function(n) {
        return n.kind === "doc";
      }).length;
      const parts = book.nodes.filter(function(n) {
        return n.kind === "dir";
      });
      if (chapters <= 20) parts.forEach(function(n) {
        ui.expanded.docs.add(n.id);
      });
      return;
    }
    if (!ui.progress || ui.progress.steps < 2 || ui.view !== "logical" || ui.userNavigated) return;
    const view = snap.views.find(function(v) {
      return v.id === "logical";
    });
    if (!view) return;
    const idx = indexView(view);
    (snap.components || []).forEach(function(c) {
      if (c.parent) return;
      const kids = (idx.children.get("l:c:" + c.id) || []).map(function(k) {
        return idx.byId.get(k);
      });
      const parts = kids.filter(function(k) {
        return k && k.kind === "component";
      }).length;
      if (parts && kids.length - parts <= 40) ui.expanded.logical.add("l:c:" + c.id);
    });
  }
  function activate(id) {
    ui.userNavigated = true;
    const view = currentView();
    if (!view) return;
    const idx = indexView(view);
    if (codeOverview()) expandedSet(idx).forEach(function(open) {
      ui.expanded.code.add(open);
    });
    const node = idx.byId.get(id);
    if (!node) return;
    const kids = idx.children.get(id) || [];
    const expanded = ui.expanded[stateKey()];
    if (kids.length) {
      if (expanded.has(id)) collapse(id, idx);
      else {
        expanded.add(id);
        ui.focus[stateKey()] = id;
      }
      ui.selected = id;
      render(expanded.has(id) ? id : null);
    } else if (node.kind === "section") {
      post("openFile", sectionTarget(node));
    } else if (node.kind === "entity") {
      post("openFile", entityTarget(node));
    } else if (node.path && (node.kind === "file" || node.kind === "doc" || node.kind === "moduleRef")) {
      post("openFile", { path: node.path });
    }
  }
  function openPRFile(path) {
    const pr = ui.payload && ui.payload.pr;
    const f = pr && pr.files.find(function(x) {
      return x.path === path;
    });
    const first = f && !f.deleted && f.ranges && f.ranges[0];
    post("openFile", first ? { path, line: first[0], endLine: first[1] } : { path });
  }
  function sectionTarget(node) {
    const target = { path: node.path, find: node.anchor || node.name };
    if (node.line) target.line = node.line;
    return target;
  }
  function entityTarget(node) {
    const target = { path: node.path };
    if (node.line) target.line = node.line;
    if (node.anchor) target.find = node.anchor;
    return target;
  }
  function collapse(id, idx) {
    ui.userNavigated = true;
    const expanded = ui.expanded[stateKey()];
    (function walk(n) {
      expanded.delete(n);
      (idx.children.get(n) || []).forEach(walk);
    })(id);
    const node = idx.byId.get(id);
    ui.focus[stateKey()] = node && node.parent != null && expanded.has(node.parent) ? node.parent : null;
  }
})(window.MVArchitecture);
;
(function(A) {
  if (!A.ready) return;
  const {
    IMPORTANCE,
    bookColor,
    bookImportance,
    changeShown,
    collapse,
    currentFilter,
    currentView,
    el,
    highlightNeighbourhood,
    indexView,
    isBook,
    isSearch,
    isTransparent,
    levelColor,
    levelRank,
    overlayApplies,
    palette,
    post,
    render,
    roleColor,
    roleNames,
    scales,
    stateKey,
    ui
  } = A;
  Object.assign(A, {
    addRow,
    codeModelOf,
    hideCodeSequence,
    isOperationRunning,
    linkButton,
    renderCodeTraces,
    renderCrumbs,
    renderDeployButton,
    renderLegend,
    renderOperations,
    showCodeSequence,
    visibleOperations
  });
  function renderCrumbs() {
    const view = currentView();
    el.crumbs.textContent = "";
    if (!view) return;
    const idx = indexView(view);
    const chain = [];
    let cur = ui.focus[stateKey()] ? idx.byId.get(ui.focus[stateKey()]) : null;
    while (cur) {
      if (!isTransparent(cur)) chain.unshift(cur);
      cur = cur.parent != null ? idx.byId.get(cur.parent) : null;
    }
    const top = document.createElement("button");
    top.className = "arch-crumb";
    top.textContent = { code: "Code architecture", logical: "Logical", modules: "Modules", deployment: "Deployment", docs: "Book", pr: "Pull request" }[ui.view];
    top.onclick = function() {
      ui.expanded[stateKey()].clear();
      ui.focus[stateKey()] = null;
      ui.selected = null;
      ui.selectedEdge = null;
      if (A.cy) {
        A.cy.elements().unselect();
        highlightNeighbourhood(null);
      }
      render();
    };
    el.crumbs.appendChild(top);
    chain.forEach(function(node) {
      const sep = document.createElement("span");
      sep.className = "arch-sep";
      sep.textContent = "\u203A";
      el.crumbs.appendChild(sep);
      const b = document.createElement("button");
      b.className = "arch-crumb";
      b.textContent = node.name;
      b.onclick = function() {
        (idx.children.get(node.id) || []).forEach(function(k) {
          collapse(k, idx);
        });
        ui.focus[stateKey()] = node.id;
        ui.selected = node.id;
        ui.selectedEdge = null;
        if (A.cy) A.cy.elements().unselect();
        render(node.id);
      };
      el.crumbs.appendChild(b);
    });
  }
  function scaleLegend(scale) {
    const wrap = document.createElement("span");
    wrap.className = "arch-scale";
    const title = document.createElement("b");
    title.textContent = scale.title;
    wrap.appendChild(title);
    scale.stops.forEach(function(stop, i) {
      const label = document.createElement("em");
      label.textContent = stop[1];
      wrap.appendChild(label);
      const next = scale.stops[i + 1];
      if (!next) return;
      const seg = document.createElement("i");
      seg.className = "arch-scale-seg";
      seg.style.background = "linear-gradient(to right, " + stop[2] + ", " + next[2] + ")";
      wrap.appendChild(seg);
    });
    return wrap;
  }
  function renderLegend() {
    const c = palette();
    el.legend.textContent = "";
    const scale = overlayApplies() && scales(c)[ui.overlay];
    const filter = overlayApplies() && currentFilter();
    if (scale) {
      el.legend.appendChild(scaleLegend(scale));
    } else if (isSearch(filter)) {
      const title = document.createElement("span");
      title.innerHTML = "<b></b>";
      title.firstChild.textContent = filter.name + " \u2014 AI search";
      el.legend.appendChild(title);
      const found = document.createElement("span");
      const dot = document.createElement("i");
      dot.style.background = levelColor(filter, filter.levels.length - 1, c);
      found.appendChild(dot);
      found.appendChild(document.createTextNode("Matters for it"));
      el.legend.appendChild(found);
      const summary = (ui.payload.searchSummaries || {})[filter.id];
      if (summary) {
        const s = document.createElement("span");
        s.className = "arch-search-summary";
        s.textContent = summary;
        s.title = summary;
        el.legend.appendChild(s);
      }
    } else if (filter) {
      const ramp = filter.levels.slice().reverse().map(function(level) {
        return [levelRank(filter, level), level, levelColor(filter, levelRank(filter, level), c) || c.line];
      });
      el.legend.appendChild(scaleLegend({ title: filter.id === "importance" ? "Importance (AI)" : filter.name + " \u2014 relevance (AI)", stops: ramp }));
    }
    const note = scale ? scale.note : filter && filter.id === "importance" ? "Rated by AI as you zoom in; a folder shows its strongest part" : isSearch(filter) ? ui.payload.status ? "Dashed = keyword candidate while the AI reads the project" : "Uncoloured = not related; a folder is red when something inside matters" : filter ? "Dashed = keyword match, solid = checked by AI; a folder shows its strongest part" : null;
    if (!scale && !filter && isBook() && A.cy && currentView()) {
      const idx = indexView(currentView());
      const rated = A.cy.nodes().some(function(n) {
        return bookImportance(idx.byId.get(n.id()), idx) != null;
      });
      if (rated) {
        const ramp = IMPORTANCE.levels.slice().reverse().map(function(level) {
          const rank = levelRank(IMPORTANCE, level);
          return [rank, level, bookColor(rank, c)];
        });
        el.legend.appendChild(scaleLegend({ title: "Importance (AI)", stops: ramp }));
      } else {
        const span = document.createElement("span");
        span.className = "arch-muted";
        span.textContent = "Colours come with Analyze: chapters and sections are rated by importance.";
        el.legend.appendChild(span);
      }
    }
    if (!scale && !filter && isBook() && currentView() && currentView().edges.some(function(e) {
      return e.kind === "related";
    })) {
      const span = document.createElement("span");
      span.className = "arch-muted";
      span.textContent = "Solid = link in the text \xB7 dashed = related (AI), shown for the selected box";
      el.legend.appendChild(span);
    }
    if (!scale && !filter && !(overlayApplies() && ui.overlay !== "none") && A.cy) {
      const present = new Set(A.cy.nodes().map(function(n) {
        const node = currentView() && indexView(currentView()).byId.get(n.id());
        return node && node.role && roleColor[node.role] ? node.role : null;
      }).filter(Boolean));
      if (present.size) {
        const title = document.createElement("span");
        const roleTitle = document.createElement("b");
        roleTitle.textContent = ui.view === "code" ? "Colour = layer" : "Colour = role (AI)";
        title.appendChild(roleTitle);
        el.legend.appendChild(title);
        Object.keys(roleNames).filter(function(r) {
          return present.has(r);
        }).forEach(function(r) {
          const span = document.createElement("span");
          const dot = document.createElement("i");
          dot.style.background = roleColor[r];
          span.appendChild(dot);
          span.appendChild(document.createTextNode(roleNames[r]));
          el.legend.appendChild(span);
        });
      }
    }
    const items = note ? [[null, note]] : overlayApplies() && ui.overlay === "pr" ? [[c.ok, "Looks correct"], [c.warn, "Concerns"], [c.bad, "Likely bug"], [c.info, "Changed, not reviewed"]] : overlayApplies() && ui.overlay === "size" ? [[c.line, "Box area grows with lines of code"]] : [];
    if (ui.prTab && ui.payload.pr && ui.overlay !== "pr") items.push([c.info, "Halo = changed (+added \u2212removed lines)"]);
    if (changeShown() && ui.payload.pr && ui.payload.pr.files.some(function(f) {
      return f.deleted;
    })) {
      items.push([c.bad, "\u2715 dashed = removed file"]);
    }
    if (overlayApplies() && ui.overlay === "tests") items.push([c.info, "Test code"]);
    const report = ui.payload.snapshot && ui.payload.snapshot.coverageReport;
    if (ui.overlay === "tests" && report) items.push([null, "Line coverage from " + report]);
    items.forEach(function(item) {
      const span = document.createElement("span");
      if (item[0]) {
        const dot = document.createElement("i");
        dot.style.background = item[0];
        span.appendChild(dot);
      }
      span.appendChild(document.createTextNode(item[1]));
      el.legend.appendChild(span);
    });
    if (ui.view === "code" && !scale && !filter) {
      const span = document.createElement("span");
      span.className = "arch-muted";
      span.textContent = "Solid arrow = fact (scanner) \xB7 dashed = inference (AI, cited)" + (codeModelOf(ui.payload.snapshot) ? "" : " \xB7 dotted layer = draft from paths");
      el.legend.appendChild(span);
    }
    const hint = document.createElement("span");
    hint.className = "arch-hint";
    hint.textContent = ui.view === "code" ? "Select a box for dependencies \xB7 Double-click to zoom in or open" : "Double-click to zoom in or open";
    el.legend.appendChild(hint);
  }
  function addRow(parent, label, value) {
    if (value == null || value === "") return;
    const row = document.createElement("div");
    row.className = "arch-row";
    const k = document.createElement("span");
    k.textContent = label;
    const v = document.createElement("span");
    v.textContent = value;
    row.appendChild(k);
    row.appendChild(v);
    parent.appendChild(row);
  }
  function linkButton(text, onClick, cls) {
    const b = document.createElement("button");
    b.className = "arch-link" + (cls ? " " + cls : "");
    b.textContent = text;
    b.onclick = onClick;
    return b;
  }
  function visibleOperations() {
    return ui.operations && Array.isArray(ui.operations.operations) ? ui.operations.operations : [];
  }
  function operationState(operation) {
    return (ui.operations && ui.operations.states || {})[operation.id] || {};
  }
  function isOperationRunning(operation) {
    return ["running", "cancelling"].indexOf(operationState(operation).state) >= 0;
  }
  function renderDeployButton() {
    const operations = visibleOperations().filter(function(o) {
      return o.kind === "deploy";
    });
    el.deploy.hidden = !operations.length;
    el.deploy.disabled = !!(ui.operations && ui.operations.readOnly);
    el.deployPicker.hidden = true;
    if (!operations.length) return;
    const running = operations.some(isOperationRunning);
    const singleState = operations.length === 1 ? operationState(operations[0]).state : null;
    el.deploy.textContent = running ? "Deploy \xB7 Running" : singleState ? "Deploy \xB7 " + singleState[0].toUpperCase() + singleState.slice(1) : "Deploy";
    el.deployPicker.textContent = "";
    const placeholder = document.createElement("option");
    placeholder.textContent = "Choose deployment\u2026";
    placeholder.value = "";
    el.deployPicker.appendChild(placeholder);
    const unnamed = operations.filter(function(o) {
      return !(o.environment || "").trim();
    });
    const groups = [];
    operations.forEach(function(o) {
      const name = (o.environment || "").trim();
      if (name && !groups.some(function(g) {
        return g.toLowerCase() === name.toLowerCase();
      })) groups.push(name);
    });
    function option(parent, o) {
      const item = document.createElement("option");
      item.value = o.id;
      item.disabled = !!(ui.operations.unavailable || {})[o.id] && !isOperationRunning(o);
      const outcome = operationState(o).state;
      item.textContent = (outcome ? outcome[0].toUpperCase() + outcome.slice(1) + " \xB7 " : "") + o.label + (o.confidence === "low" && o.origin !== "user" && o.discovered && o.command === o.discovered.command ? " \xB7 Low confidence" : "") + (outcome === "dispatched" ? " \xB7 Remote run is not tracked" : "");
      parent.appendChild(item);
    }
    unnamed.sort(function(a, b) {
      return a.label.localeCompare(b.label);
    }).forEach(function(o) {
      option(el.deployPicker, o);
    });
    groups.forEach(function(name) {
      const members = operations.filter(function(o) {
        return (o.environment || "").trim().toLowerCase() === name.toLowerCase();
      });
      const group = document.createElement("optgroup");
      group.label = name + (members.some(isOperationRunning) ? " \xB7 Running" : "");
      members.sort(function(a, b) {
        return a.label.localeCompare(b.label);
      }).forEach(function(o) {
        option(group, o);
      });
      el.deployPicker.appendChild(group);
    });
  }
  function renderOperations(d, node) {
    if (ui.view !== "deployment" || !ui.operations) return;
    const state2 = ui.operations;
    const title = document.createElement("h5");
    title.textContent = "Project operations";
    d.appendChild(title);
    if (state2.error) {
      const error = document.createElement("p");
      error.className = "arch-error";
      error.textContent = state2.error;
      d.appendChild(error);
      return;
    }
    if (state2.message) {
      const message = document.createElement("p");
      message.className = "arch-muted";
      message.textContent = state2.message;
      d.appendChild(message);
    }
    if (state2.readOnly) {
      const warning = document.createElement("p");
      warning.className = "arch-error";
      warning.textContent = "This operations file uses a newer schema version. Update MarkView to edit or run operations.";
      d.appendChild(warning);
    }
    const all = visibleOperations();
    if (!all.length) {
      const p = document.createElement("p");
      p.className = "arch-muted";
      p.textContent = "No runnable procedure is known for this project.";
      d.appendChild(p);
    }
    const currentNodeIDs = new Set((currentView() && currentView().nodes || []).map(function(n) {
      return n.id;
    }));
    const related = node ? all.filter(function(o) {
      return (o.nodes || []).some(function(n) {
        return currentNodeIDs.has(n.id) ? n.id === node.id : n.name === node.name;
      });
    }) : [];
    function row(operation, highlighted) {
      const wrapper = document.createElement("div");
      wrapper.className = "arch-operation" + (highlighted ? " related" : "");
      const heading = document.createElement("strong");
      heading.textContent = operation.label + (operation.environment ? " \xB7 " + operation.environment : "") + " \xB7 " + operation.kind;
      wrapper.appendChild(heading);
      const status = operationState(operation);
      const badges = document.createElement("div");
      badges.className = "arch-badges";
      const edited = operation.origin === "user" || operation.discovered && (operation.command !== operation.discovered.command || operation.cwd !== operation.discovered.cwd);
      const marks = [
        edited ? operation.origin === "user" ? "User-added" : "User-edited" : operation.confidence,
        status.state,
        operation.remoteTrigger ? "Remote trigger" : null,
        operation.cwd.indexOf("..") === 0 || operation.cwd.indexOf("~") === 0 || operation.cwd.indexOf("/") === 0 ? "Outside project" : null
      ];
      marks.filter(Boolean).forEach(function(mark) {
        const badge = document.createElement("span");
        badge.textContent = mark;
        badges.appendChild(badge);
      });
      wrapper.appendChild(badges);
      if (status.state === "dispatched") {
        const remote = document.createElement("p");
        remote.className = "arch-muted";
        remote.textContent = "Remote run is not tracked.";
        wrapper.appendChild(remote);
      }
      const command = document.createElement("code");
      command.textContent = operation.command;
      wrapper.appendChild(command);
      addRow(wrapper, "Directory", operation.cwd);
      (operation.provenance || []).forEach(function(source) {
        addRow(wrapper, "Source", source.location + (source.line ? ":" + source.line : "") + " \xB7 " + source.kind);
      });
      (operation.prerequisites || []).forEach(function(item) {
        addRow(wrapper, "Prerequisite", item);
      });
      if (edited && operation.discovered && (operation.command !== operation.discovered.command || operation.cwd !== operation.discovered.cwd)) {
        addRow(wrapper, "Discovery suggests", operation.discovered.command + " \xB7 " + operation.discovered.cwd);
      }
      if (status.definitionNotice) addRow(wrapper, "Changed", status.definitionNotice);
      const unavailable = (state2.unavailable || {})[operation.id];
      if (unavailable) addRow(wrapper, "Unavailable", unavailable);
      const actions = document.createElement("div");
      actions.className = "arch-operation-actions";
      const run = linkButton(isOperationRunning(operation) ? "Open output" : "Run", function() {
        post(isOperationRunning(operation) ? "operationOpen" : "operationRun", { id: operation.id });
      }, "arch-action");
      run.disabled = !!unavailable && !isOperationRunning(operation);
      actions.appendChild(run);
      if (status.state && !isOperationRunning(operation)) {
        actions.appendChild(linkButton("Last run", function() {
          post("operationOpen", { id: operation.id });
        }, "arch-action"));
      }
      const edit = linkButton("Edit", function() {
        post("operationEdit", { id: operation.id });
      }, "arch-action");
      edit.disabled = !!state2.readOnly;
      actions.appendChild(edit);
      if (edited && operation.discovered && (operation.command !== operation.discovered.command || operation.cwd !== operation.discovered.cwd)) {
        const adopt = linkButton("Adopt discovered", function() {
          post("operationAdopt", { id: operation.id });
        }, "arch-action");
        adopt.disabled = !!state2.readOnly;
        actions.appendChild(adopt);
      }
      wrapper.appendChild(actions);
      d.appendChild(wrapper);
    }
    if (related.length) {
      const h = document.createElement("h5");
      h.textContent = "Related to " + node.name;
      d.appendChild(h);
      related.forEach(function(o) {
        row(o, true);
      });
    }
    const kinds = ["deploy", "build", "test", "run", "install", "clean", "restart", "other"];
    const groups = /* @__PURE__ */ new Map();
    all.filter(function(o) {
      return related.indexOf(o) < 0;
    }).forEach(function(o) {
      const kind = o.kind || "other";
      if (!groups.has(kind)) groups.set(kind, []);
      groups.get(kind).push(o);
    });
    function kindRank(kind) {
      return kinds.indexOf(kind) < 0 ? kinds.length : kinds.indexOf(kind);
    }
    Array.from(groups.keys()).sort(function(a, b) {
      return kindRank(a) - kindRank(b) || a.localeCompare(b);
    }).forEach(function(kind) {
      const members = groups.get(kind).sort(function(a, b) {
        return a.label.localeCompare(b.label);
      });
      const h = document.createElement("h5");
      h.textContent = kind.charAt(0).toUpperCase() + kind.slice(1) + " (" + members.length + ")";
      d.appendChild(h);
      members.forEach(function(o) {
        row(o, false);
      });
    });
    const addOperation = linkButton("Add operation", function() {
      post("operationAdd");
    }, "arch-action");
    addOperation.disabled = !!state2.readOnly;
    d.appendChild(addOperation);
    if (state2.sourcesChanged) {
      const hint = document.createElement("p");
      hint.className = "arch-muted";
      hint.textContent = "Sources changed since the last discovery. The operations remain available.";
      d.appendChild(hint);
    }
    if (state2.discoveryPhase) {
      const progress = document.createElement("p");
      progress.className = "arch-muted";
      progress.textContent = "Discovering operations \xB7 " + state2.discoveryPhase + "\u2026";
      d.appendChild(progress);
      d.appendChild(linkButton("Cancel discovery", function() {
        post("operationCancelDiscovery");
      }, "arch-action"));
    } else {
      const discover = linkButton(
        state2.hasFile ? "Re-discover" : "Discover operations",
        function() {
          post("operationDiscover");
        },
        "arch-action"
      );
      discover.disabled = !!state2.readOnly;
      d.appendChild(discover);
    }
    const report = state2.discoveryReport;
    if (report) {
      const heading = document.createElement("h5");
      heading.textContent = "Discovery report";
      d.appendChild(heading);
      const message = document.createElement("p");
      message.textContent = report.message;
      d.appendChild(message);
      (report.externalFolders || []).forEach(function(path) {
        addRow(d, "External folder read", path);
      });
      (report.rejectedReferences || []).forEach(function(path) {
        addRow(d, "Reference skipped", path);
      });
      (report.webSources || []).forEach(function(url) {
        addRow(d, "Web source", url);
      });
      if (!report.webSearched) addRow(d, "Web", "Not searched");
      (report.proposals || []).forEach(function(operation, index) {
        const box = document.createElement("div");
        box.className = "arch-operation related";
        const name = document.createElement("strong");
        name.textContent = operation.label + " \xB7 Proposal from outside the project";
        box.appendChild(name);
        const command = document.createElement("code");
        command.textContent = operation.command;
        box.appendChild(command);
        addRow(box, "Confidence", operation.confidence);
        (operation.provenance || []).forEach(function(source) {
          addRow(box, "Source", source.location);
        });
        box.appendChild(linkButton("Accept", function() {
          post("operationAcceptProposal", { index });
        }, "arch-action"));
        box.appendChild(linkButton("Reject", function() {
          post("operationRejectProposal", { index });
        }, "arch-action"));
        d.appendChild(box);
      });
      (report.notDetermined || []).forEach(function(item, index) {
        const box = document.createElement("div");
        box.className = "arch-operation";
        const name = document.createElement("strong");
        name.textContent = item.label + " \xB7 Not determined";
        box.appendChild(name);
        addRow(box, "Reason", item.reason);
        addRow(box, "Investigated", item.investigated);
        box.appendChild(linkButton("Add command", function() {
          post("operationAddUnknown", { index });
        }, "arch-action"));
        d.appendChild(box);
      });
      d.appendChild(linkButton("Dismiss report", function() {
        post("operationDismissReport");
      }, "arch-action"));
    }
  }
  function codeScope(node) {
    return node ? node.id : "code:";
  }
  function codeModelOf(snap) {
    return snap && snap.codeModel ? snap.codeModel : null;
  }
  function moduleRoot(snap) {
    return ((snap.views.find(function(v) {
      return v.id === "modules";
    }) || {}).nodes || []).find(function(n) {
      return n.id === "m:";
    });
  }
  function relativeTime(iso) {
    const date = new Date(iso);
    if (isNaN(date.getTime())) return "";
    const seconds = Math.max(0, (Date.now() - date.getTime()) / 1e3);
    if (seconds < 60) return "just now";
    const minutes = Math.round(seconds / 60);
    if (minutes < 60) return minutes + (minutes === 1 ? " minute ago" : " minutes ago");
    const hours = Math.round(minutes / 60);
    if (hours < 24) return hours + (hours === 1 ? " hour ago" : " hours ago");
    const days = Math.round(hours / 24);
    if (days < 7) return days === 1 ? "yesterday" : days + " days ago";
    return "on " + date.toLocaleDateString();
  }
  function codeStatusText(snap) {
    const state2 = ui.payload.automaticState || { kind: "idle" };
    switch (state2.kind) {
      case "scanning":
      case "analyzing":
        return "Analyzing code in the background\u2026" + (state2.step ? " " + state2.step : "");
      case "done":
        return "Analyzed " + relativeTime(state2.date);
      case "off":
        return "Automatic analysis is off";
      case "unavailable":
        return "AI analysis unavailable: " + (state2.reason || "no assistant");
      case "tooLarge":
        return "Project too large for automatic analysis (" + (state2.files || 0) + " files); use Refresh";
      case "skipped":
        return state2.reason || "";
      default:
        return snap.codeModel && snap.codeModel.analyzedAt ? "Analyzed " + relativeTime(snap.codeModel.analyzedAt) : "";
    }
  }
  function sequenceInfo(snap, i) {
    const info = (ui.payload.codeSequenceInfo || [])[i];
    if (info) return info;
    const trace = snap.codeSequences[i];
    const root = moduleRoot(snap);
    return {
      title: trace.diagram.title,
      scope: trace.scope,
      auto: !!trace.auto,
      stale: !!(root && root.signature !== trace.signature),
      createdAt: trace.createdAt
    };
  }
  function sequenceRow(snap, i) {
    const info = sequenceInfo(snap, i);
    const row = document.createElement("div");
    row.className = "arch-sequence";
    row.appendChild(linkButton(info.title, function() {
      showCodeSequence(i);
    }, "arch-action"));
    const badges = document.createElement("span");
    badges.className = "arch-badges";
    const kind = document.createElement("span");
    kind.textContent = info.auto ? "Automatic" : "Manual";
    kind.title = info.auto ? "Chosen and traced by the automatic analysis" : "Traced from your question; kept across automatic refreshes";
    badges.appendChild(kind);
    if (info.stale) {
      const stale = document.createElement("span");
      stale.className = "arch-warn";
      stale.textContent = "stale";
      stale.title = "A cited source file changed since this trace";
      badges.appendChild(stale);
    }
    row.appendChild(badges);
    return row;
  }
  const LEVEL_NAMES = { full: "full", partial: "partial", notAnalyzed: "not analyzed" };
  function renderCoverage(d, snap) {
    const report = snap.codeCoverage;
    if (!report) return;
    const languages = report.languages || [];
    const details = document.createElement("details");
    details.className = "arch-coverage";
    details.open = languages.some(function(l) {
      return l.level !== "full";
    });
    const summary = document.createElement("summary");
    summary.textContent = "What was understood";
    details.appendChild(summary);
    if (languages.length) {
      const table = document.createElement("table");
      const head = table.createTHead().insertRow();
      ["Language", "Level", "Full", "Partial", "Not analyzed"].forEach(function(text) {
        const cell = document.createElement("th");
        cell.textContent = text;
        head.appendChild(cell);
      });
      const body = table.createTBody();
      languages.forEach(function(l) {
        const row = body.insertRow();
        row.className = "arch-level-" + l.level;
        [l.language, LEVEL_NAMES[l.level] || l.level, l.full, l.partial, l.notAnalyzed].forEach(function(value, i) {
          const cell = row.insertCell();
          cell.textContent = String(value == null ? "" : value);
          if (i >= 2) cell.className = "arch-num";
        });
      });
      details.appendChild(table);
    } else {
      const p = document.createElement("p");
      p.className = "arch-muted";
      p.textContent = "No source files were scanned.";
      details.appendChild(p);
    }
    addRow(details, "Files outside the components", String(report.unassignedFiles || 0));
    if (!report.hasModel) {
      const p = document.createElement("p");
      p.className = "arch-muted";
      p.textContent = "Local scan only: the AI analysis assigns files to components.";
      details.appendChild(p);
    }
    if ((report.reasons || []).length) {
      const list = document.createElement("ul");
      list.className = "arch-coverage-reasons";
      report.reasons.forEach(function(reason) {
        const item = document.createElement("li");
        item.textContent = reason;
        list.appendChild(item);
      });
      details.appendChild(list);
    }
    d.appendChild(details);
  }
  function renderFactLegend(d) {
    const legend = document.createElement("div");
    legend.className = "arch-fact-legend";
    [
      ["arch-fact", "Fact", "found in the source by the scanner (solid arrow)"],
      ["arch-inference", "Inference", "read from the code by the AI, with a citation (dashed arrow)"],
      ["arch-draft", "Draft", "layers guessed from file paths until the analysis runs (dotted box)"]
    ].forEach(function(item) {
      const span = document.createElement("span");
      const mark = document.createElement("i");
      mark.className = item[0];
      span.appendChild(mark);
      const name = document.createElement("b");
      name.textContent = item[1];
      span.appendChild(name);
      span.appendChild(document.createTextNode(" " + item[2]));
      legend.appendChild(span);
    });
    d.appendChild(legend);
  }
  function renderCodeTraces(d, node, view, snap) {
    if (!view.nodes.some(function(n) {
      return n.kind === "file";
    })) return;
    const scope = codeScope(node);
    const section = document.createElement("div");
    section.className = "arch-code-traces";
    const sequences = snap.codeSequences || [];
    if (!node) {
      const status = codeStatusText(snap);
      if (status) {
        const line = document.createElement("p");
        line.className = "arch-code-status";
        line.textContent = status;
        section.appendChild(line);
      }
      const heading = document.createElement("h5");
      heading.textContent = "Scenarios";
      section.appendChild(heading);
      if (sequences.length) sequences.forEach(function(trace, i) {
        section.appendChild(sequenceRow(snap, i));
      });
      else {
        const p = document.createElement("p");
        p.className = "arch-muted";
        p.textContent = "No scenarios traced yet.";
        section.appendChild(p);
      }
    }
    const title = document.createElement("h5");
    title.textContent = "Trace a scenario" + (node ? " in " + node.name : " in the code");
    section.appendChild(title);
    const note = document.createElement("p");
    note.className = "arch-muted";
    note.textContent = "Layers \u2192 components \u2192 files \u2192 symbols. Double-click to explore. " + (!snap.codeModel && (snap.logicalDraft || !(snap.components || []).length) ? "Draft layers use file paths; the analysis refines components from source. " : "") + "A sequence is an AI interpretation of one code path, with source evidence; it is not a runtime trace." + (ui.codeHidden.size ? " Use Show all to include filtered source code." : "");
    section.appendChild(note);
    const root = moduleRoot(snap);
    if (snap.codeModel && root && snap.codeModel.signature !== root.signature) {
      const warning = document.createElement("p");
      warning.className = "arch-muted";
      warning.textContent = "Source changed since the architecture analysis. Refresh to update the components.";
      section.appendChild(warning);
    }
    const component = snap.codeModel && node && snap.codeModel.components.find(function(c) {
      return c.id === node.component;
    });
    if (component) {
      const match = /^(.*):(\d+)$/.exec(component.evidence);
      if (match) section.appendChild(linkButton("Source: " + component.evidence, function() {
        post("openFile", { path: match[1], line: Number(match[2]) });
      }, "arch-path"));
    }
    const input = document.createElement("textarea");
    input.className = "arch-code-question";
    input.maxLength = 4e3;
    input.setAttribute("aria-label", "Scenario to trace");
    input.placeholder = "e.g. How is a document saved?";
    input.value = ui.codeQuestions[scope] || "";
    const submit = linkButton(ui.payload.busy ? "Analysis in progress\u2026" : "Draw sequence", function() {
      const question = input.value.trim();
      if (!question || ui.payload.busy) return;
      ui.codeAwaitingScope = scope;
      ui.codePreviousTime = (snap.codeSequences || []).map(function(s) {
        return s.createdAt;
      }).join("|");
      post("traceCode", { scope, question });
    }, "arch-action");
    submit.disabled = ui.payload.busy || !input.value.trim();
    input.oninput = function() {
      ui.codeQuestions[scope] = input.value;
      submit.disabled = ui.payload.busy || !input.value.trim();
    };
    section.appendChild(input);
    section.appendChild(submit);
    if (node) sequences.forEach(function(trace, i) {
      if (trace.scope === scope) section.appendChild(sequenceRow(snap, i));
    });
    else {
      renderCoverage(section, snap);
      renderFactLegend(section);
    }
    d.appendChild(section);
  }
  let sequenceRenderToken = 0;
  function hideCodeSequence() {
    ++sequenceRenderToken;
    ui.codeSequenceIndex = null;
    document.getElementById("arch-code-sequence").hidden = true;
  }
  document.getElementById("arch-code-sequence-close").onclick = hideCodeSequence;
  function showCodeSequence(i) {
    const trace = ((ui.payload.snapshot || {}).codeSequences || [])[i];
    const source = (ui.payload.codeSequenceDiagrams || [])[i];
    if (!trace || !source) return;
    ui.codeSequenceIndex = i;
    const token = ++sequenceRenderToken;
    const panel = document.getElementById("arch-code-sequence");
    panel.hidden = false;
    document.getElementById("arch-code-sequence-title").textContent = trace.diagram.title;
    document.getElementById("arch-code-sequence-takeaway").textContent = trace.diagram.takeaway;
    document.getElementById("arch-code-sequence-omitted").textContent = trace.diagram.omitted || "";
    const sources = document.getElementById("arch-code-sequence-sources");
    sources.textContent = "";
    const subtitle = document.createElement("h4");
    subtitle.textContent = "Messages and source evidence";
    sources.appendChild(subtitle);
    trace.diagram.edges.forEach(function(edge) {
      const row = document.createElement("p");
      row.textContent = edge.label;
      sources.appendChild(row);
      const match = /^(.*):(\d+)$/.exec(edge.evidence || "");
      if (match) sources.appendChild(linkButton(edge.evidence, function() {
        post("openFile", { path: match[1], line: Number(match[2]) });
      }, "arch-path"));
    });
    const body = document.getElementById("arch-code-sequence-svg");
    body.textContent = "Drawing sequence\u2026";
    try {
      mermaid.render("code-sequence-" + token, source).then(function(result) {
        if (token !== sequenceRenderToken) return;
        body.innerHTML = window.mvKit.sanitizeMermaidSvg(result.svg);
      }).catch(function() {
        if (token === sequenceRenderToken) body.textContent = "The sequence could not be rendered. Its messages and source evidence are listed below.";
      });
    } catch (e) {
      body.textContent = "The sequence could not be rendered. Its messages and source evidence are listed below.";
    }
  }
})(window.MVArchitecture);
;
(function(A) {
  if (!A.ready) return;
  const {
    activate,
    addRow,
    ago,
    aiFilters,
    bookText,
    codeViews,
    currentFilter,
    currentView,
    descendantsFiles,
    el,
    entityTarget,
    expandedSet,
    fileKey,
    hiddenTags,
    indexView,
    isBook,
    isHidden,
    isSearch,
    kindLabel,
    levelRank,
    linkButton,
    openPRFile,
    overlayApplies,
    overlayInfo,
    palette,
    post,
    prByNode,
    ratingOf,
    render,
    renderCodeTraces,
    renderOperations,
    sectionTarget,
    ui,
    undescribedChapters
  } = A;
  Object.assign(A, { renderDetails, renderFilterOptions, renderNewFilterForm });
  function renderDetails() {
    const d = el.details;
    const oldAnswerBody = d.querySelector(".arch-understanding-body");
    const answerScroll = oldAnswerBody ? oldAnswerBody.scrollTop : 0;
    d.textContent = "";
    const filter = currentFilter();
    const understanding = filter && (ui.payload.understandingAnswers || {})[filter.id];
    if (understanding) {
      renderUnderstanding(d, filter, understanding);
      const body = d.querySelector(".arch-understanding-body");
      if (body) body.scrollTop = answerScroll;
      const key = filter.id + ":" + understanding.state;
      if (ui.answerDisplayKey !== key) {
        d.scrollTop = 0;
        ui.answerDisplayKey = key;
      }
    }
    const view = currentView();
    const snap = ui.payload && ui.payload.snapshot;
    if (!view || !snap) {
      if (ui.view === "deployment") renderOperations(d, null);
      return;
    }
    const idx = indexView(view);
    const node = ui.selected ? idx.byId.get(ui.selected) : null;
    if (ui.view === "code") renderCodeTraces(d, node, view, snap);
    if (!node && ui.selectedEdge && ui.selectedEdge.view === ui.view) {
      renderEdgeDetails(d, idx, ui.selectedEdge);
      return;
    }
    if (!understanding && !node && isSearch(currentFilter()) && overlayApplies() && (ui.payload.searchAnswers || {})[currentFilter().id]) {
      renderSearchAnswer(d, currentFilter(), ui.payload.searchAnswers[currentFilter().id]);
      return;
    }
    if (!node && (ui.view === "pr" || ui.prTab)) {
      renderPRPanel(d, snap, idx);
      return;
    }
    const showsChange = ui.view === "pr" || ui.prTab || overlayApplies() && ui.overlay === "pr";
    if (node && showsChange && node.path && node.kind === "file" && ui.payload.pr && ui.payload.pr.files.some(function(f) {
      return f.path === node.path;
    })) {
      renderPRFile(d, node.path);
      return;
    }
    if (!node && isBook()) {
      renderBookOverview(d, view, idx, snap);
      return;
    }
    if (!node) {
      const h2 = document.createElement("h4");
      h2.textContent = ui.view === "code" && snap.codeModel ? snap.codeModel.name : ui.view === "logical" && snap.systemName ? snap.systemName : "Overview";
      d.appendChild(h2);
      if (ui.view === "code" && snap.codeModel) {
        const p2 = document.createElement("p");
        p2.textContent = snap.codeModel.purpose;
        d.appendChild(p2);
      }
      if (ui.view === "logical" && snap.systemPurpose) {
        const p2 = document.createElement("p");
        p2.textContent = snap.systemPurpose;
        d.appendChild(p2);
      }
      renderReport(d, view, idx);
      const active = currentFilter();
      if (active && active.id !== "importance") {
        d.appendChild(linkButton('Delete filter "' + active.name + '"', function() {
          post("deleteFilter", { id: active.id });
          ui.overlay = "none";
        }, "arch-action"));
      }
      const files = view.nodes.filter(function(n) {
        return n.kind === "file" || n.kind === "doc";
      }).length;
      addRow(d, ui.view === "docs" ? "Documents" : "Files", files ? String(files) : "");
      addRow(d, "Connections", String(view.edges.length));
      addRow(d, "Scanned", snap.scannedAt ? new Date(snap.scannedAt).toLocaleString() : "");
      const analyzedAt = ui.view === "code" && snap.codeModel ? snap.codeModel.analyzedAt : snap.enrichedAt;
      addRow(d, "AI analysis", analyzedAt ? new Date(analyzedAt).toLocaleString() : snap.codeModel && ui.view === "code" ? "available" : "not run");
      if (overlayApplies() && ui.overlay === "pr" && ui.payload.pr) {
        const pr = ui.payload.pr;
        const sec = document.createElement("h5");
        sec.textContent = pr.source.title;
        d.appendChild(sec);
        addRow(d, "Changed files", String(pr.files.length));
        if (pr.reviewSummary) {
          const p2 = document.createElement("p");
          p2.textContent = pr.reviewSummary;
          d.appendChild(p2);
        }
        pr.files.forEach(function(f) {
          d.appendChild(changeRow(f));
        });
      }
      if (ui.view === "deployment" && !view.nodes.some(function(n) {
        return n.kind !== "root";
      })) {
        const p2 = document.createElement("p");
        p2.textContent = "The deployment view is mapped by AI from the project\u2019s build and deploy files. Click Analyze.";
        d.appendChild(p2);
      }
      renderOperations(d, null);
      const p = document.createElement("p");
      p.className = "arch-muted";
      p.textContent = "Select a box for details. Double-click to zoom in; use the path above to zoom out.";
      d.appendChild(p);
      return;
    }
    const h = document.createElement("h4");
    h.textContent = node.name;
    d.appendChild(h);
    if (ui.view === "deployment") renderOperations(d, node);
    const badges = document.createElement("div");
    badges.className = "arch-badges";
    const lineBadge = isBook() && node.line ? "lines " + node.line + (node.endLine && node.endLine !== node.line ? "\u2013" + node.endLine : "") : null;
    [kindLabel(node), node.role, isBook() && node.kind === "section" ? null : node.language, node.tech, lineBadge].forEach(function(b) {
      if (!b) return;
      const s = document.createElement("span");
      s.textContent = b;
      badges.appendChild(s);
    });
    d.appendChild(badges);
    const describing = (ui.payload.describing || []).indexOf(node.id) >= 0;
    if (isBook()) renderBookLineage(d, node, idx);
    const borrowed = !node.summary && bookText(node);
    if (node.summary) {
      const p = document.createElement("p");
      p.textContent = node.summary;
      d.appendChild(p);
    } else if (borrowed && borrowed.summary) {
      if (borrowed.kind === "doc" && borrowed.name !== node.name) {
        const t = document.createElement("p");
        t.className = "arch-muted";
        t.textContent = borrowed.name;
        d.appendChild(t);
      }
      const p = document.createElement("p");
      p.textContent = borrowed.summary;
      d.appendChild(p);
      if (borrowed.kind === "doc" && !borrowed.summarySignature) {
        const n = document.createElement("p");
        n.className = "arch-muted";
        n.textContent = "From the document's first paragraph; Analyze writes the AI's annotation.";
        d.appendChild(n);
      }
    } else if (isBook() && ["doc", "section"].indexOf(node.kind) >= 0) {
      renderDescribeChapter(d, node, idx);
    } else if (codeViews[ui.view] && ["dir", "package", "file"].indexOf(node.kind) >= 0 && !borrowed) {
      const p = document.createElement("p");
      p.className = "arch-muted";
      p.textContent = describing || ui.describeRequested.has(node.id) ? "Describing\u2026" : "";
      d.appendChild(p);
      if (!ui.describeRequested.has(node.id)) {
        ui.describeRequested.add(node.id);
        post("describe", { view: ui.view === "code" ? "modules" : ui.view, id: ui.view === "code" ? "m:" + node.path : node.id });
        p.textContent = "Describing\u2026";
      }
    }
    const rating = ratingOf(node);
    if (rating) {
      const sec = document.createElement("h5");
      sec.textContent = currentFilter().name + ": " + rating.level;
      d.appendChild(sec);
      if (rating.reason) {
        const p = document.createElement("p");
        p.textContent = rating.reason;
        d.appendChild(p);
      }
    }
    const comps = snap.components || [];
    if (ui.view !== "code" && codeViews[ui.view] && comps.length && ["dir", "package", "file"].indexOf(node.kind) >= 0 && node.path != null) {
      const structural = ui.view === "logical" ? (snap.views.find(function(v) {
        return v.id === "modules";
      }) || { nodes: [] }).nodes.find(function(n) {
        return n.path === node.path && n.kind === node.kind;
      }) || node : node;
      const sec = document.createElement("h5");
      sec.textContent = "Logical component";
      d.appendChild(sec);
      const select = document.createElement("select");
      select.title = "Where this belongs in the Logical view. Pick another component to move it; your choice is kept over the AI's.";
      const overridden = snap.overrides && snap.overrides[node.path];
      const aiComp = comps.find(function(c) {
        return c.id === (snap.assignments && (function() {
          let p = node.path;
          while (true) {
            const a = snap.assignments[p];
            if (a) return a.component;
            if (!p) return null;
            p = p.indexOf("/") >= 0 ? p.slice(0, p.lastIndexOf("/")) : "";
          }
        })());
      });
      const auto = document.createElement("option");
      auto.value = "";
      auto.textContent = aiComp ? "AI: " + aiComp.name : "AI: not assigned";
      select.appendChild(auto);
      comps.forEach(function(comp) {
        const o = document.createElement("option");
        o.value = comp.id;
        o.textContent = comp.name;
        if (overridden === comp.id) o.selected = true;
        select.appendChild(o);
      });
      select.onchange = function() {
        post("setComponent", { path: node.path, component: select.value });
      };
      d.appendChild(select);
      const tags = structural.tags || [];
      if (tags.length) {
        const b = document.createElement("div");
        b.className = "arch-badges";
        tags.forEach(function(t) {
          const sp = document.createElement("span");
          sp.textContent = t;
          b.appendChild(sp);
        });
        d.appendChild(b);
      }
    }
    if (node.path != null && node.path !== "") {
      const openable = ["file", "doc", "section", "entity"].indexOf(node.kind) >= 0;
      const title = node.kind === "section" ? node.path + (node.line ? ":" + node.line + (node.endLine && node.endLine !== node.line ? "\u2013" + node.endLine : "") : "") + " \u203A " + node.name : node.kind === "entity" ? node.path + (node.line ? ":" + node.line : "") : node.path;
      d.appendChild(linkButton(title, function() {
        post("openFile", node.kind === "section" ? sectionTarget(node) : node.kind === "entity" ? entityTarget(node) : { path: node.path });
      }, "arch-path" + (openable ? "" : " arch-reveal")));
    }
    if ((ui.view === "logical" || ui.view === "code") && node.kind === "file" && node.path) {
      const reading = (ui.payload.outlining || []).indexOf(node.path) >= 0;
      const hasContents = (idx.children.get(node.id) || []).length > 0;
      const button = linkButton(
        reading ? "Outlining with AI\u2026" : hasContents ? "Deepen with AI" : "Outline with AI",
        function() {
          if (!reading) post("outlineFile", { path: node.path });
        },
        "arch-action"
      );
      if (reading) button.disabled = true;
      d.appendChild(button);
    }
    renderInsightButton(d, node);
    addRow(
      d,
      ["collection", "group"].indexOf(node.kind) >= 0 ? "Items" : isBook() ? "Chapters" : "Files",
      ["file", "doc", "entity", "section"].indexOf(node.kind) >= 0 ? "" : node.files ? String(node.files) : ""
    );
    if (isBook() && ["doc", "dir", "root"].indexOf(node.kind) >= 0) {
      const sections = view.nodes.filter(function(n) {
        return n.kind === "section" && (node.kind === "doc" ? n.path === node.path : isUnder(n, node.id, idx));
      }).length;
      addRow(d, "Sections", sections ? String(sections) : "");
    }
    addRow(d, "Lines", node.loc ? String(node.loc) : "");
    const kids = idx.children.get(node.id) || [];
    if (kids.length) {
      const expanded = expandedSet(idx).has(node.id);
      d.appendChild(linkButton(expanded ? "Zoom out of this" : "Zoom into this", function() {
        activate(node.id);
      }, "arch-action"));
    }
    if (isBook()) {
      renderBookRefs(d, node, idx, view);
    } else if (A.cy && A.cy.getElementById(node.id).length) {
      const drawn = A.cy.getElementById(node.id);
      const outs = drawn.union(drawn.descendants()).outgoers("edge").filter(function(e) {
        return !e.target().same(drawn) && !drawn.descendants().contains(e.target());
      });
      const ins = drawn.union(drawn.descendants()).incomers("edge").filter(function(e) {
        return !e.source().same(drawn) && !drawn.descendants().contains(e.source());
      });
      addRow(d, "Depends on", outs.length ? String(outs.length) : "");
      addRow(d, "Used by", ins.length ? String(ins.length) : "");
    }
    if (codeViews[ui.view]) {
      const metrics = snap.metrics || {};
      const files = descendantsFiles(node.id, idx, []).map(function(id) {
        return idx.byId.get(id);
      }).filter(function(n) {
        return n && n.kind === "file";
      }).map(function(n) {
        return metrics[fileKey(n)];
      }).filter(Boolean);
      if (files.length) {
        const sec = document.createElement("h5");
        sec.textContent = "Health";
        d.appendChild(sec);
        const sum = function(k) {
          return files.reduce(function(a, m) {
            return a + (m[k] || 0);
          }, 0);
        };
        const sources = files.filter(function(m) {
          return !m.isTest;
        });
        const tested = sources.filter(function(m) {
          return m.tested;
        }).length;
        const worstFn = files.reduce(function(a, m) {
          return (m.maxFunctionComplexity || 0) > (a ? a.maxFunctionComplexity : 0) ? m : a;
        }, null);
        addRow(d, "Functions", String(sum("functions")));
        if (worstFn) addRow(d, "Most complex", worstFn.maxFunctionComplexity + (worstFn.maxFunctionName ? " \u2014 " + worstFn.maxFunctionName : ""));
        addRow(d, "Functions > 10", String(sum("complexFunctions")));
        addRow(d, "Commits", sum("commits") ? String(sum("commits")) : "");
        addRow(d, "Bug-fix commits", sum("bugfixes") ? String(sum("bugfixes")) : "0");
        const newest = files.reduce(function(a, m) {
          return Math.max(a, m.lastChanged || 0);
        }, 0);
        if (newest) addRow(d, "Last changed", ago(newest));
        if (files.length > 1) {
          const recent = files.filter(function(m) {
            return m.lastChanged && Date.now() / 1e3 - m.lastChanged < 182 * 86400;
          }).length;
          addRow(d, "Changed in 6 months", recent + " of " + files.length + " files");
        }
        if (node.kind === "file" && metrics[fileKey(node)]) {
          const m = metrics[fileKey(node)];
          addRow(d, "Tests", m.isTest ? "this is a test file" : m.tested ? "tested" : "none found");
          if (m.lineCoverage != null) addRow(d, "Line coverage", Math.round(m.lineCoverage * 100) + "%");
          (m.testFiles || []).forEach(function(t) {
            d.appendChild(linkButton(t, function() {
              post("openFile", { path: t });
            }, "arch-path"));
          });
        } else if (sources.length) {
          addRow(d, "Tested files", tested + " of " + sources.length);
        }
      }
      const cov = snap.coverage || {};
      if (node.kind === "file") {
        const c = cov[fileKey(node)];
        const sec = document.createElement("h5");
        sec.textContent = "Documentation";
        d.appendChild(sec);
        const status = c ? c.status : "none";
        const p = document.createElement("p");
        p.textContent = status === "fresh" ? "Documented." : status === "stale" ? "Documented, but the code changed after the documents." : "No document mentions this file or its folders.";
        d.appendChild(p);
        (c ? c.docs : []).forEach(function(doc) {
          d.appendChild(linkButton(doc, function() {
            post("openFile", { path: doc, find: node.name });
          }, "arch-path"));
        });
      } else if (ui.overlay === "coverage") {
        const info = overlayInfo(node, idx);
        if (info && info.total) {
          const sec = document.createElement("h5");
          sec.textContent = "Documentation";
          d.appendChild(sec);
          addRow(d, "Documented", info.fresh + " of " + info.total);
          addRow(d, "Outdated docs", info.stale ? String(info.stale) : "");
          addRow(d, "Undocumented", info.none ? String(info.none) : "");
        }
      }
      if (ui.payload.pr) {
        const pr = prByNode();
        const changes = descendantsFiles(node.id, idx, []).map(function(id) {
          return pr.get(fileKey(idx.byId.get(id)));
        }).filter(Boolean);
        if (changes.length) {
          const sec = document.createElement("h5");
          sec.textContent = "Changes in " + ui.payload.pr.source.title;
          d.appendChild(sec);
          changes.forEach(function(f) {
            d.appendChild(changeRow(f));
          });
        }
      }
    }
  }
  function isUnder(node, ancestorId, idx) {
    let cur = node.parent != null ? idx.byId.get(node.parent) : null;
    while (cur) {
      if (cur.id === ancestorId) return true;
      cur = cur.parent != null ? idx.byId.get(cur.parent) : null;
    }
    return false;
  }
  function renderBookOverview(d, view, idx, snap) {
    const root = view.nodes.find(function(n) {
      return n.kind === "root";
    });
    const h = document.createElement("h4");
    h.textContent = root && root.name ? root.name : "Book";
    d.appendChild(h);
    if (root && root.summary) {
      const p2 = document.createElement("p");
      p2.textContent = root.summary;
      d.appendChild(p2);
    }
    const form = document.createElement("form");
    form.className = "temp-filter arch-ask";
    const input = document.createElement("input");
    input.placeholder = "Ask the book, e.g. how are releases published?";
    input.style.width = "100%";
    form.appendChild(input);
    form.onsubmit = function(e) {
      e.preventDefault();
      const text = input.value.trim();
      if (text) A.askBook(text);
    };
    d.appendChild(form);
    const hint = document.createElement("p");
    hint.className = "arch-muted";
    hint.textContent = "A question gets an answer (what, why, how, where it comes from) with the sections it rests on; press Enter.";
    d.appendChild(hint);
    renderReport(d, view, idx);
    const active = currentFilter();
    if (active && active.id !== "importance") {
      d.appendChild(linkButton('Delete filter "' + active.name + '"', function() {
        post("deleteFilter", { id: active.id });
        ui.overlay = "none";
      }, "arch-action"));
    }
    const count = function(kind) {
      return view.nodes.filter(function(n) {
        return n.kind === kind;
      }).length;
    };
    const chapters = count("doc");
    addRow(d, "Parts", count("dir") ? String(count("dir")) : "");
    addRow(d, "Chapters", chapters ? String(chapters) : "");
    addRow(d, "Sections", count("section") ? String(count("section")) : "");
    const links = view.edges.filter(function(e) {
      return e.kind === "links";
    }).length;
    const related = view.edges.filter(function(e) {
      return e.kind === "related";
    }).length;
    addRow(d, "Cross-references", links || related ? links + " in the text" + (related ? ", " + related + " related (AI)" : "") : "");
    addRow(d, "Scanned", snap.scannedAt ? new Date(snap.scannedAt).toLocaleString() : "");
    const left = undescribedChapters(view).length;
    if (chapters) addRow(d, "AI annotations", chapters - left + " of " + chapters + " chapters");
    if (left) {
      const b = linkButton(ui.payload.busy ? "Annotating\u2026" : "Describe remaining chapters (" + left + ")", function() {
        post("describeBook", {});
      }, "arch-action");
      if (ui.payload.busy) b.disabled = true;
      d.appendChild(b);
      if (!snap.enrichedAt && !ui.payload.busy) {
        const p2 = document.createElement("p");
        p2.className = "arch-muted";
        p2.textContent = "Analyze annotates every chapter and section: what each says, how important it is, and what else to read.";
        d.appendChild(p2);
      }
    }
    const insight = linkButton("Recursive Insight of the book", function() {
      post("recursiveInsight", { path: "" });
    }, "arch-action");
    insight.title = "A layered narrative of all the documents, to read and dive into level by level";
    d.appendChild(insight);
    const p = document.createElement("p");
    p.className = "arch-muted";
    p.textContent = "Select a part, chapter or section for details. Double-click opens a chapter's sections; double-click a section to read it.";
    d.appendChild(p);
  }
  function renderInsightButton(d, node) {
    if (!isBook() || node.path == null || node.kind !== "dir" && node.kind !== "doc") return;
    const b = linkButton(
      node.kind === "dir" ? "Recursive Insight of this part" : "Recursive Insight of this chapter",
      function() {
        post("recursiveInsight", { path: node.path });
      },
      "arch-action"
    );
    b.title = node.kind === "dir" ? "A layered narrative of this folder's documents, to dive into level by level" : "A layered narrative of this document, to dive into level by level";
    d.appendChild(b);
  }
  function renderBookLineage(d, node, idx) {
    const chain = [];
    let cur = node.parent != null ? idx.byId.get(node.parent) : null;
    while (cur && cur.kind !== "root") {
      chain.unshift(cur);
      cur = cur.parent != null ? idx.byId.get(cur.parent) : null;
    }
    if (!chain.length) return;
    const row = document.createElement("div");
    row.className = "arch-badges";
    const label = document.createElement("span");
    label.textContent = "In:";
    row.appendChild(label);
    chain.forEach(function(step, i) {
      if (i) {
        const sep = document.createElement("span");
        sep.textContent = "\u203A";
        row.appendChild(sep);
      }
      const b = linkButton(step.name, function() {
        window.architectureFocus(step.id, "docs");
      }, "arch-link");
      b.title = kindLabel(step) + (step.path ? " \xB7 " + step.path : "");
      row.appendChild(b);
    });
    d.appendChild(row);
  }
  function renderDescribeChapter(d, node, idx) {
    let chapter = node;
    while (chapter && chapter.kind !== "doc") chapter = chapter.parent != null ? idx.byId.get(chapter.parent) : null;
    if (!chapter) return;
    const describing = (ui.payload.describing || []).indexOf(chapter.id) >= 0;
    const p = document.createElement("p");
    p.className = "arch-muted";
    p.textContent = describing ? "Describing\u2026" : "Not annotated by the AI yet.";
    d.appendChild(p);
    if (!describing) {
      const b = linkButton(ui.payload.busy ? "Busy\u2026" : "Describe this chapter", function() {
        post("describeBook", { path: chapter.path });
      }, "arch-action");
      if (ui.payload.busy) b.disabled = true;
      d.appendChild(b);
    }
  }
  function renderBookRefs(d, node, idx, view) {
    const inside = /* @__PURE__ */ new Set([node.id]);
    (function walk(id) {
      (idx.children.get(id) || []).forEach(function(k) {
        inside.add(k);
        walk(k);
      });
    })(node.id);
    const out = [], inn = [];
    view.edges.forEach(function(e) {
      if (e.kind !== "links" && e.kind !== "related") return;
      const s = inside.has(e.source), t = inside.has(e.target);
      if (s && !t) out.push(e);
      else if (t && !s) inn.push(e);
    });
    function list(title, edges, otherOf) {
      if (!edges.length) return;
      const sec = document.createElement("h5");
      sec.textContent = title + " (" + edges.length + ")";
      d.appendChild(sec);
      const seen = /* @__PURE__ */ new Set();
      edges.forEach(function(e) {
        const other = idx.byId.get(otherOf(e));
        if (!other || seen.size >= 20) return;
        const key = other.id + "|" + e.kind;
        if (seen.has(key)) return;
        seen.add(key);
        let text = other.name;
        if (other.kind !== "doc" && other.path) text += " (" + other.path.split("/").pop() + ")";
        if (e.kind === "related") text += " \u2014 related (AI)" + (e.label ? ": " + e.label : "");
        const b = linkButton(text, function() {
          window.architectureFocus(other.id, "docs");
        }, "arch-path");
        b.title = (other.path || other.name) + (e.kind === "related" ? " \xB7 found by the AI" : " \xB7 linked in the text");
        d.appendChild(b);
      });
    }
    list("Refers to", out, function(e) {
      return e.target;
    });
    list("Referred to by", inn, function(e) {
      return e.source;
    });
  }
  function renderReport(d, view, idx) {
    if (!overlayApplies() || ui.overlay === "pr") return;
    const snap = ui.payload.snapshot;
    const metrics = snap.metrics || {}, cov = snap.coverage || {};
    const leaves = view.nodes.filter(function(n) {
      return ["file", "doc", "section", "component"].indexOf(n.kind) >= 0;
    }).filter(function(n) {
      return !isHidden(n, idx);
    });
    const score = {
      complexity: function(n) {
        const m = metrics[fileKey(n)];
        return m && n.kind === "file" ? [m.maxFunctionComplexity, m.maxFunctionComplexity + (m.maxFunctionName ? " " + m.maxFunctionName : "")] : null;
      },
      bugs: function(n) {
        const m = metrics[fileKey(n)];
        return m && n.kind === "file" && m.bugfixes ? [m.bugfixes, m.bugfixes + " fixes"] : null;
      },
      tests: function(n) {
        const m = metrics[fileKey(n)];
        return m && n.kind === "file" && !m.isTest && !m.tested ? [m.loc, m.loc + " lines, no tests"] : null;
      },
      coverage: function(n) {
        const c = cov[fileKey(n)];
        const m = metrics[fileKey(n)];
        return c && c.status !== "fresh" && n.kind === "file" ? [(m ? m.loc : 0) + (c.status === "stale" ? 1e6 : 0), c.status === "stale" ? "docs outdated" : "undocumented"] : null;
      },
      freshness: function(n) {
        const m = metrics[fileKey(n)];
        return m && (n.kind === "file" || n.kind === "doc") ? [m.lastChanged, ago(m.lastChanged)] : null;
      },
      size: function(n) {
        return n.loc && (n.kind === "file" || n.kind === "doc") ? [n.loc, n.loc + " lines"] : null;
      }
    }[ui.overlay] || currentFilter() && function(n) {
      const r = ratingOf(n);
      return r ? [levelRank(currentFilter(), r.level), r.level] : null;
    };
    if (!score) return;
    const chapterTitle = function(n) {
      if (n.kind !== "section" || !n.path) return n.name;
      const chapter = view.nodes.find(function(c) {
        return c.kind === "doc" && c.path === n.path;
      });
      return (chapter ? chapter.name + " \u203A " : "") + n.name;
    };
    const ranked = leaves.map(function(n) {
      const sc = score(n);
      return sc ? { node: n, value: sc[0], label: sc[1], title: chapterTitle(n) } : null;
    }).filter(Boolean).sort(function(a, b) {
      return b.value - a.value;
    }).slice(0, 15);
    const titles = {
      complexity: "Most complex functions",
      bugs: "Bug hotspots",
      tests: "Largest untested files",
      coverage: "Documentation gaps",
      freshness: "Recently changed",
      size: "Largest files"
    };
    const sec = document.createElement("h5");
    sec.textContent = titles[ui.overlay] || (currentFilter() ? currentFilter().name + " \u2014 strongest" : "");
    d.appendChild(sec);
    if (currentFilter() && currentFilter().criterion) {
      const q = document.createElement("p");
      q.className = "arch-muted";
      q.textContent = currentFilter().criterion;
      d.appendChild(q);
    }
    if (!ranked.length) {
      const p = document.createElement("p");
      p.className = "arch-muted";
      p.textContent = currentFilter() ? "Zoom in: the AI rates each level as you open it." : "Nothing to report.";
      d.appendChild(p);
      return;
    }
    const grid = document.createElement("div");
    grid.className = "arch-rank";
    ranked.forEach(function(r) {
      const b = document.createElement("button");
      b.textContent = r.title || r.node.name;
      b.title = r.node.path || r.node.name;
      b.onclick = function() {
        window.architectureFocus(r.node.id);
      };
      const v = document.createElement("span");
      v.textContent = r.label;
      grid.appendChild(b);
      grid.appendChild(v);
    });
    d.appendChild(grid);
  }
  function renderEdgeDetails(d, idx, edge) {
    const a = idx.byId.get(edge.source), b = idx.byId.get(edge.target);
    const h = document.createElement("h4");
    h.textContent = (a ? a.name : edge.source) + " \u2192 " + (b ? b.name : edge.target);
    d.appendChild(h);
    const kind = document.createElement("div");
    kind.className = "arch-badges";
    const chip = document.createElement("span");
    chip.textContent = edge.kind + (edge.label ? " \xB7 " + edge.label : "");
    kind.appendChild(chip);
    d.appendChild(kind);
    [a, b].forEach(function(n) {
      if (!n) return;
      d.appendChild(linkButton((n === a ? "From: " : "To: ") + n.name, function() {
        ui.selectedEdge = null;
        ui.selected = n.id;
        render(n.id);
      }, "arch-path"));
    });
    const sec = document.createElement("h5");
    sec.textContent = "Why this link exists";
    d.appendChild(sec);
    if (edge.kind === "related") {
      const why = document.createElement("p");
      why.className = "arch-answer";
      why.textContent = (edge.label ? edge.label + " " : "") + "(related content found by the AI while annotating the book)";
      d.appendChild(why);
      return;
    }
    if (edge.view === "code") {
      const text = document.createElement("p");
      text.textContent = edge.evidence.length ? "Inference: a source-backed dependency inferred by the code analysis." : "Fact: a static dependency found by the source scanner. Trace a scenario to inspect execution order.";
      d.appendChild(text);
      edge.evidence.forEach(function(source) {
        const match = /^(.*):(\d+)$/.exec(source);
        if (match) d.appendChild(linkButton(source, function() {
          post("openFile", { path: match[1], line: Number(match[2]) });
        }, "arch-path"));
      });
      [a, b].forEach(function(n) {
        if (n && n.path) d.appendChild(linkButton(n.path, function() {
          post("openFile", { path: n.path });
        }, "arch-path"));
      });
      return;
    }
    const note = (ui.payload.edgeNotes || {})[edge.view + "|" + edge.source + "|" + edge.target];
    const p = document.createElement("p");
    p.className = "arch-answer";
    p.textContent = note && note.text ? note.text : "The AI is reading the code behind this link\u2026";
    d.appendChild(p);
    if (note && note.pending) {
      const w = document.createElement("p");
      w.className = "arch-muted";
      w.textContent = "Working\u2026";
      d.appendChild(w);
    }
    if (note && !note.pending) {
      d.appendChild(linkButton("Explain again", function() {
        post("explainEdge", { view: edge.view, source: edge.source, target: edge.target, kind: edge.kind, label: edge.label || void 0, again: true });
      }, "arch-action"));
    }
    if (note && note.evidence && note.evidence.length) {
      const ev = document.createElement("h5");
      ev.textContent = "Code behind it";
      d.appendChild(ev);
      note.evidence.forEach(function(line) {
        const m = /^(.*?):(\d+): (.*)$/.exec(line);
        if (!m) return;
        const b2 = linkButton(m[1].split("/").pop() + ":" + m[2] + "  " + m[3], function() {
          post("openFile", { path: m[1], line: parseInt(m[2], 10), endLine: parseInt(m[2], 10) });
        }, "arch-path");
        b2.title = m[1] + ":" + m[2];
        d.appendChild(b2);
      });
    }
  }
  function revealUnderstandingSource(source) {
    if (source.kind === "document" || source.kind === "commit" || source.kind === "pr") {
      post("openUnderstandingSource", { filter: currentFilter().id, source: source.id });
      return;
    }
    const views = (ui.payload.snapshot || {}).views || [];
    let view;
    let node;
    if (source.kind === "component") {
      view = views.find(function(v) {
        return v.id === "logical";
      });
      node = view && view.nodes.find(function(n) {
        return n.id === "l:c:" + source.target;
      });
    } else if (source.kind === "deployment") {
      view = views.find(function(v) {
        return v.id === "deployment";
      });
      node = view && view.nodes.find(function(n) {
        return n.id.slice(2) === source.target;
      });
    } else {
      view = views.find(function(v) {
        return v.id === ui.view && v.nodes.some(function(n) {
          return n.path === source.path && n.kind === "file";
        });
      }) || views.find(function(v) {
        return v.id === "modules";
      });
      node = view && view.nodes.find(function(n) {
        return n.path === source.path && n.kind === "file";
      });
    }
    if (!node) {
      if (source.kind === "code") post("openFile", { path: source.path, line: source.start, endLine: source.end, fromSearch: true });
      return;
    }
    ui.onlyFlagged = false;
    ui.selectedEdge = null;
    hiddenTags().clear();
    window.architectureFocus(node.id, view.id);
    A.renderToolbar();
  }
  function renderUnderstanding(d, filter, result) {
    const panel = document.createElement("section");
    panel.className = "arch-understanding";
    d.appendChild(panel);
    const heading = document.createElement("h4");
    heading.textContent = "Answer";
    panel.appendChild(heading);
    const question = document.createElement("p");
    question.className = "arch-question";
    question.textContent = result.question;
    panel.appendChild(question);
    if ((result.attachments || []).length) {
      const attached = document.createElement("p");
      attached.className = "arch-muted";
      attached.textContent = "Attachments: " + result.attachments.map(function(path) {
        return path.split("/").pop();
      }).join(", ");
      panel.appendChild(attached);
    }
    const actions = document.createElement("div");
    actions.className = "arch-understanding-actions";
    panel.appendChild(actions);
    if (result.state === "ready" && result.answer) {
      const save = linkButton("Save as research", function() {
        post("saveSearchAnswer", { filter: filter.id });
      }, "arch-action");
      save.disabled = result.saveMessage === "Saving\u2026";
      actions.appendChild(save);
    } else if (result.state === "failed") {
      actions.appendChild(linkButton("Retry", function() {
        post("retryUnderstanding", { filter: filter.id });
      }, "arch-action"));
    }
    actions.appendChild(linkButton("Close this search", function() {
      post("deleteFilter", { id: filter.id });
      ui.overlay = "none";
    }, "arch-action"));
    if (result.saveMessage) {
      const saved = document.createElement("p");
      saved.className = "arch-muted";
      saved.textContent = result.saveMessage;
      panel.appendChild(saved);
    }
    const body = document.createElement("div");
    body.className = "arch-understanding-body";
    panel.appendChild(body);
    if (result.state !== "ready" || !result.answer) {
      const message = document.createElement("p");
      message.setAttribute("role", "status");
      message.className = result.state === "failed" ? "arch-error" : "arch-working";
      message.textContent = result.state === "failed" ? "Could not answer: " + (result.message || "The AI returned an empty answer.") : result.message || "Reading the project\u2026";
      body.appendChild(message);
      return;
    }
    const answer = result.answer;
    const sources = new Map((answer.sources || []).map(function(s) {
      return [s.id, s];
    }));
    function evidenceButton(source, text) {
      const b = linkButton(text, function() {
        revealUnderstandingSource(source);
      }, "arch-path");
      b.title = source.kind + ": " + (source.path ? source.path + ":" + source.start : source.target);
      return b;
    }
    ["what", "why", "how", "origin"].forEach(function(key) {
      const section = answer[key];
      if (!section) return;
      const h = document.createElement("h5");
      h.textContent = key[0].toUpperCase() + key.slice(1);
      body.appendChild(h);
      const text = document.createElement("div");
      text.className = "arch-answer";
      text.textContent = section.text;
      body.appendChild(text);
      if (key === "origin" && !answer.originFound) {
        const missing = document.createElement("p");
        missing.className = "arch-muted";
        missing.textContent = "No origin source found.";
        body.appendChild(missing);
      }
      (section.sources || []).forEach(function(id) {
        const source = sources.get(id);
        if (source) body.appendChild(evidenceButton(source, "[" + id + "] " + source.label));
      });
    });
    if (sources.size) {
      const h = document.createElement("h5");
      h.textContent = "Sources";
      body.appendChild(h);
      sources.forEach(function(source) {
        body.appendChild(evidenceButton(source, "[" + source.id + "] " + source.label));
      });
    }
  }
  function renderSearchAnswer(d, filter, answer) {
    const h = document.createElement("h4");
    h.textContent = answer.question || filter.name;
    d.appendChild(h);
    if (answer.answer) {
      const p = document.createElement("div");
      p.className = "arch-answer";
      p.textContent = answer.answer;
      d.appendChild(p);
    } else {
      const summary = (ui.payload.searchSummaries || {})[filter.id];
      if (summary) {
        const p = document.createElement("p");
        p.textContent = summary;
        d.appendChild(p);
      }
    }
    (answer.steps || []).forEach(function(step) {
      if (!step.places || !step.places.length) return;
      const sec = document.createElement("h5");
      sec.textContent = step.title;
      d.appendChild(sec);
      step.places.forEach(function(place) {
        const b = linkButton(place.path.split("/").pop() + ":" + place.start + "  " + place.title, function() {
          post("openFile", { path: place.path, line: place.start, endLine: place.end, fromSearch: true });
        }, "arch-path");
        b.title = place.path + ":" + place.start + "\u2013" + place.end + "\n" + place.why;
        d.appendChild(b);
        if (place.why) {
          const w = document.createElement("div");
          w.className = "arch-muted arch-why";
          w.textContent = place.why;
          d.appendChild(w);
        }
      });
    });
    const active = filter;
    const save = linkButton("Save to docs/research", function() {
      post("saveSearchAnswer", { filter: active.id });
    }, "arch-action");
    save.title = "Keep this answer and its places as a Markdown document";
    d.appendChild(save);
    d.appendChild(linkButton("Close this search", function() {
      post("deleteFilter", { id: active.id });
      ui.overlay = "none";
    }, "arch-action"));
  }
  function renderAsk(d, path) {
    const pr = ui.payload.pr;
    const chat = (pr.chat || []).filter(function(entry) {
      return (entry.path || null) === (path || null);
    });
    if (chat.length) {
      const box = document.createElement("div");
      box.className = "arch-chat";
      chat.forEach(function(entry) {
        const q = document.createElement("div");
        q.className = "q";
        q.textContent = entry.question;
        box.appendChild(q);
        const a = document.createElement("div");
        a.className = "a";
        a.textContent = entry.answer || (entry.pending ? "Thinking\u2026" : "");
        if (entry.pending && entry.answer) a.textContent += " \u2026";
        box.appendChild(a);
      });
      d.appendChild(box);
    }
    const form = document.createElement("form");
    form.className = "arch-ask";
    const input = document.createElement("textarea");
    input.placeholder = path ? "Ask AI about this file\u2019s changes\u2026" : "Ask AI about this change\u2026";
    input.rows = 2;
    const send = document.createElement("button");
    send.type = "submit";
    send.className = "arch-btn";
    send.textContent = "Ask";
    form.appendChild(input);
    form.appendChild(send);
    const key = path || "*";
    ui.askDraft = ui.askDraft || {};
    input.value = ui.askDraft[key] || "";
    input.addEventListener("input", function() {
      ui.askDraft[key] = input.value;
    });
    input.addEventListener("focus", function() {
      ui.askFocus = key;
    });
    input.addEventListener("blur", function() {
      if (ui.askFocus === key) ui.askFocus = null;
    });
    if (ui.askFocus === key) setTimeout(function() {
      input.focus();
      input.selectionStart = input.selectionEnd = input.value.length;
    }, 0);
    const submit = function(e) {
      if (e) e.preventDefault();
      const text = input.value.trim();
      if (!text) return;
      ui.askDraft[key] = "";
      post("askPR", { question: text, path: path || "" });
    };
    form.addEventListener("submit", submit);
    input.addEventListener("keydown", function(e) {
      if (e.key === "Enter" && !e.shiftKey) submit(e);
    });
    d.appendChild(form);
  }
  function renderPRFile(d, path) {
    const pr = ui.payload.pr;
    const f = pr.files.find(function(x) {
      return x.path === path;
    });
    const h = document.createElement("h4");
    h.textContent = path.split("/").pop();
    d.appendChild(h);
    const sub = document.createElement("div");
    sub.className = "arch-muted";
    sub.textContent = path + "  +" + f.additions + " \u2212" + f.deletions;
    d.appendChild(sub);
    d.appendChild(linkButton("Open file", function() {
      openPRFile(path);
    }, "arch-action"));
    renderChangeExplanation(d, f);
    if (f.summary || (f.findings || []).length) d.appendChild(changeRow(f));
    renderDiffBox(d, path, null);
    const sec = document.createElement("h5");
    sec.textContent = "Ask AI";
    d.appendChild(sec);
    renderAsk(d, path);
  }
  function renderChangeExplanation(d, f) {
    const p = document.createElement("p");
    if (f.changeSummary) {
      p.textContent = f.changeSummary;
    } else if (f.explaining) {
      p.className = "arch-muted";
      p.textContent = "Explaining the changes\u2026";
    } else {
      ui.explainRequested = ui.explainRequested || /* @__PURE__ */ new Set();
      const key = ui.payload.pr.source.id + "|" + f.path;
      if (!ui.explainRequested.has(key)) {
        ui.explainRequested.add(key);
        post("explainPRFile", { path: f.path });
      }
      p.className = "arch-muted";
      p.textContent = "Explaining the changes\u2026";
    }
    d.appendChild(p);
  }
  function renderDiffBox(d, path, range) {
    const pr = ui.payload.pr;
    const diff = pr.fileDiff && pr.fileDiff.path === path ? pr.fileDiff.text : null;
    if (diff == null) {
      if (ui.diffRequested !== path) {
        ui.diffRequested = path;
        post("prFileDiff", { path });
      }
      const p = document.createElement("p");
      p.className = "arch-muted";
      p.textContent = "Loading the diff\u2026";
      d.appendChild(p);
      return;
    }
    const box = document.createElement("div");
    box.className = "arch-diff";
    let newLine = 0;
    let hunk = null;
    diff.split("\n").forEach(function(line) {
      const row = document.createElement("div");
      const num = document.createElement("b");
      if (line.indexOf("@@") === 0) {
        const m = /\+(\d+)/.exec(line);
        newLine = m ? parseInt(m[1], 10) : newLine;
        row.className = "hunk";
        row.textContent = line;
        hunk = row;
        if (!range) box.appendChild(row);
        return;
      }
      let at = null;
      if (line[0] === "+") {
        row.className = "add";
        at = newLine++;
        num.textContent = at;
      } else if (line[0] === "-") {
        row.className = "del";
      } else {
        at = newLine++;
        num.textContent = at;
      }
      if (range) {
        const position = at != null ? at : newLine;
        if (position < range[0] || position > range[1]) return;
        if (hunk) {
          box.appendChild(hunk);
          hunk = null;
        }
      }
      row.appendChild(num);
      row.appendChild(document.createTextNode(line));
      if (at != null) row.onclick = function() {
        post("openFile", { path, line: at, endLine: at });
      };
      box.appendChild(row);
    });
    d.appendChild(box);
  }
  function renderPRPanel(d, snap, idx) {
    const pr = ui.payload.pr;
    const h = document.createElement("h4");
    h.textContent = pr ? pr.source.title : "Pull request";
    d.appendChild(h);
    if (!pr) {
      const p = document.createElement("p");
      p.textContent = "Choose a pull request, your branch or your uncommitted changes above. The picture shows the parts of the X-Ray they touch; Analyze PR adds the AI\u2019s architectural review.";
      d.appendChild(p);
      return;
    }
    if (pr.info) renderPRHeader(d, pr.info);
    const a = pr.analysis;
    if (pr.reviewOutdated) {
      const warn = document.createElement("p");
      warn.className = "arch-muted";
      warn.textContent = "The code changed since this review and analysis. Use Review again for a fresh one.";
      d.appendChild(warn);
    }
    if (pr.analyzing) {
      const p = document.createElement("p");
      p.className = "arch-muted";
      p.textContent = "Analysing the change\u2026";
      d.appendChild(p);
    } else if (!a) {
      d.appendChild(linkButton("Analyze PR (AI)", function() {
        post("analyzePR");
      }, "arch-action"));
    }
    if (a) {
      const verdict = document.createElement("div");
      verdict.className = "arch-badges";
      const chip = document.createElement("span");
      chip.textContent = { approve: "looks good", attention: "needs attention", risky: "risky" }[a.verdict] || a.verdict;
      verdict.appendChild(chip);
      d.appendChild(verdict);
      const p = document.createElement("p");
      p.textContent = a.summary;
      d.appendChild(p);
      if (a.impact.length) {
        const sec2 = document.createElement("h5");
        sec2.textContent = "Impact";
        d.appendChild(sec2);
        const names = new Map((snap.components || []).map(function(comp) {
          return [comp.id, comp.name];
        }));
        a.impact.forEach(function(i) {
          const row = linkButton((names.get(i.component) || i.component || "Other") + " \xB7 " + i.risk + " \u2014 " + i.note, function() {
            ui.selected = "l:c:" + i.component;
            render("l:c:" + i.component);
          });
          d.appendChild(row);
        });
      }
      if (a.risks.length) {
        const sec2 = document.createElement("h5");
        sec2.textContent = "Risks";
        d.appendChild(sec2);
        const list = document.createElement("ul");
        a.risks.forEach(function(r) {
          const li = document.createElement("li");
          li.textContent = r;
          list.appendChild(li);
        });
        d.appendChild(list);
      }
      if (a.checks.length) {
        const sec2 = document.createElement("h5");
        sec2.textContent = "What to check";
        d.appendChild(sec2);
        a.checks.forEach(function(check) {
          d.appendChild(linkButton(check.path.split("/").pop() + (check.line ? ":" + check.line : "") + " \u2014 " + check.note, function() {
            post("openFile", { path: check.path, line: check.line || void 0 });
          }));
        });
      }
    }
    renderPRTasks(d, pr);
    const ask = document.createElement("h5");
    ask.textContent = "Ask AI";
    d.appendChild(ask);
    renderAsk(d, null);
    const deps = pr.dependencies || [];
    if (deps.length) {
      const sec2 = document.createElement("h5");
      sec2.textContent = "Links";
      d.appendChild(sec2);
      deps.forEach(function(dep) {
        const p = document.createElement("div");
        p.className = "arch-muted";
        p.textContent = (dep.change === "added" ? "+ " : "\u2212 ") + dep.source.split("/").pop() + " \u2192 " + dep.target.split("/").pop();
        d.appendChild(p);
      });
    }
    const sec = document.createElement("h5");
    sec.textContent = pr.files.length + " changed files";
    d.appendChild(sec);
    if (pr.reviewSummary) {
      const p = document.createElement("p");
      p.textContent = pr.reviewSummary;
      d.appendChild(p);
    }
    pr.files.forEach(function(f) {
      d.appendChild(changeRow(f));
    });
  }
  function renderPRTasks(d, pr) {
    let count = 0;
    pr.files.forEach(function(f) {
      const findings = (f.findings || []).filter(function(x) {
        return !x.dismissed;
      }).length;
      count += findings || (f.verdict && f.verdict !== "ok" && f.summary ? 1 : 0);
    });
    if (pr.analysis) count += pr.analysis.checks.length + pr.analysis.risks.length;
    if (!count) return;
    const sec = document.createElement("h5");
    sec.textContent = count + (count === 1 ? " task" : " tasks") + " found";
    d.appendChild(sec);
    const row = document.createElement("div");
    row.className = "arch-task-actions";
    const send = linkButton("Send to terminal", function() {
      post("prTasksToTerminal");
    }, "arch-action");
    send.title = "Type the list at the AI terminal prompt (not sent: check it and press Enter)";
    const copy = linkButton("Copy", function() {
      post("copyPRTasks");
      copy.textContent = "Copied";
      setTimeout(function() {
        copy.textContent = "Copy";
      }, 1500);
    }, "arch-action");
    copy.title = "Copy the list as markdown tasks";
    const fixAll = linkButton("\u2726 Fix all", function() {
      post("prFixAll");
    }, "arch-action");
    fixAll.title = "Send every task to the AI terminal and let it fix them (a GitHub pull request is checked out first)";
    row.appendChild(fixAll);
    row.appendChild(send);
    row.appendChild(copy);
    d.appendChild(row);
  }
  function renderPRHeader(d, info) {
    const box = document.createElement("div");
    box.className = "arch-pr-header";
    const badges = document.createElement("div");
    badges.className = "arch-badges";
    function badge(text, cls) {
      const s = document.createElement("span");
      s.textContent = text;
      if (cls) s.className = cls;
      badges.appendChild(s);
    }
    badge(info.isDraft ? "draft" : info.state.toLowerCase(), info.state === "OPEN" ? "arch-ok" : "");
    if (info.checksTotal) {
      badge(
        (info.checksFailed ? "\u2717 " : info.checksPassed === info.checksTotal ? "\u2713 " : "\u25CF ") + info.checksPassed + "/" + info.checksTotal + " checks",
        info.checksFailed ? "arch-bad" : info.checksPassed === info.checksTotal ? "arch-ok" : "arch-warn"
      );
    }
    const decision = { APPROVED: "approved", CHANGES_REQUESTED: "changes requested", REVIEW_REQUIRED: "review required" }[info.reviewDecision];
    if (decision) badge(decision, info.reviewDecision === "APPROVED" ? "arch-ok" : "arch-warn");
    if (info.mergeable === "CONFLICTING") badge("conflicts", "arch-bad");
    box.appendChild(badges);
    const meta = document.createElement("div");
    meta.className = "arch-muted";
    meta.textContent = (info.author ? info.author + " \xB7 " : "") + info.head + " \u2192 " + info.base;
    box.appendChild(meta);
    if (info.state === "OPEN") {
      let act2 = function(label, op, needsText, title) {
        const b = linkButton(label, function() {
          const body = (ui.prNotes[key] || "").trim();
          if (needsText && !body) {
            note.focus();
            note.placeholder = "Write what should change first";
            return;
          }
          ui.prNoteSent[key] = true;
          post("prAction", { op, body, method: ui.prMergeMethod || "squash" });
        }, "arch-action");
        if (title) b.title = title;
        if (info.busy) b.disabled = true;
        row.appendChild(b);
      }, armed2 = function(op) {
        return ui.prArmed && ui.prArmed.key === key + op && Date.now() < ui.prArmed.until;
      }, confirmed2 = function(op, button, again, label, send) {
        return linkButton(armed2(op) ? again : label, function() {
          if (!armed2(op)) {
            ui.prArmed = { key: key + op, until: Date.now() + 4e3 };
            button.self.textContent = again;
            setTimeout(function() {
              if (button.self.isConnected && !armed2(op)) button.self.textContent = label;
            }, 4100);
            return;
          }
          ui.prArmed = null;
          send();
        }, "arch-action");
      };
      var act = act2, armed = armed2, confirmed = confirmed2;
      ui.prNotes = ui.prNotes || {};
      ui.prNoteSent = ui.prNoteSent || {};
      const key = String(info.number);
      if (ui.prNoteSent[key] && !info.busy && info.message) {
        if (info.ok) ui.prNotes[key] = "";
        ui.prNoteSent[key] = false;
      }
      const note = document.createElement("textarea");
      note.className = "arch-pr-note";
      note.placeholder = "Review comment (optional for Approve)";
      note.value = ui.prNotes[key] || "";
      note.addEventListener("input", function() {
        ui.prNotes[key] = note.value;
      });
      note.addEventListener("focus", function() {
        ui.prNoteFocus = key;
      });
      note.addEventListener("blur", function() {
        if (ui.prNoteFocus === key) ui.prNoteFocus = null;
      });
      note.addEventListener("select", function() {
        ui.prNoteCaret = [note.selectionStart, note.selectionEnd];
      });
      note.addEventListener("keyup", function() {
        ui.prNoteCaret = [note.selectionStart, note.selectionEnd];
      });
      note.addEventListener("click", function() {
        ui.prNoteCaret = [note.selectionStart, note.selectionEnd];
      });
      if (ui.prNoteFocus === key) setTimeout(function() {
        note.focus();
        const caret = ui.prNoteCaret || [note.value.length, note.value.length];
        note.selectionStart = caret[0];
        note.selectionEnd = caret[1];
      }, 0);
      box.appendChild(note);
      const row = document.createElement("div");
      row.className = "arch-task-actions";
      act2("Approve", "approve", false);
      act2("Request changes", "requestChanges", true);
      act2("Comment", "comment", true);
      box.appendChild(row);
      const mergeRow = document.createElement("div");
      mergeRow.className = "arch-task-actions";
      const method = document.createElement("select");
      method.className = "arch-pr-method";
      [["squash", "Squash and merge"], ["merge", "Merge commit"], ["rebase", "Rebase and merge"]].forEach(function(m) {
        const o = document.createElement("option");
        o.value = m[0];
        o.textContent = m[1];
        method.appendChild(o);
      });
      method.value = ui.prMergeMethod || "squash";
      method.onchange = function() {
        ui.prMergeMethod = method.value;
      };
      const mergeRef = {}, closeRef = {};
      const merge = confirmed2("merge", mergeRef, "Click again to merge", "Merge", function() {
        post("prAction", { op: "merge", method: method.value });
      });
      mergeRef.self = merge;
      if (info.busy || info.mergeable === "CONFLICTING") merge.disabled = true;
      const close = confirmed2("close", closeRef, "Click again to close", "Close PR", function() {
        post("prAction", { op: "close" });
      });
      closeRef.self = close;
      mergeRow.appendChild(method);
      mergeRow.appendChild(merge);
      mergeRow.appendChild(close);
      box.appendChild(mergeRow);
    }
    const open = linkButton("Open on GitHub \u2197", function() {
      post("openURL", { url: info.url });
    }, "arch-action");
    box.appendChild(open);
    if (info.busy) {
      const p = document.createElement("p");
      p.className = "arch-muted";
      p.textContent = "Working\u2026";
      box.appendChild(p);
    }
    if (info.message) {
      const p = document.createElement("p");
      p.className = "arch-muted";
      p.textContent = info.message;
      box.appendChild(p);
    }
    d.appendChild(box);
  }
  function findingRow(f, finding, index) {
    const pr = ui.payload && ui.payload.pr;
    const wrap = document.createElement("div");
    wrap.className = "arch-finding-box" + (finding.dismissed ? " arch-dismissed" : "");
    const b = linkButton("L" + finding.line + " \xB7 " + finding.message, function() {
      post("openFile", { path: f.path, line: finding.line, endLine: finding.line });
    }, "arch-finding arch-" + finding.severity);
    wrap.appendChild(b);
    const row = document.createElement("div");
    row.className = "arch-finding-actions";
    const fields = { path: f.path, index };
    function act(label, action, title) {
      const a = linkButton(label, function() {
        post(action, fields);
      });
      a.title = title;
      row.appendChild(a);
      return a;
    }
    if (!finding.dismissed) {
      act("\u2726 Fix it", "prFindingFix", "Send to the AI terminal to fix (a GitHub pull request is checked out first)");
      const ex = act(finding.explaining ? "Explaining\u2026" : "\u2726 Explain", "prFindingExplain", "Why this is a problem and how to fix it");
      if (finding.explaining) ex.disabled = true;
      if (pr && pr.info) {
        const c = act(finding.commented ? "\u2713 Commented" : "Comment on PR", "prFindingComment", "Post as a review comment on this line");
        if (finding.commented) c.disabled = true;
        if (finding.issueURL) {
          act("Issue \u2197", "openURL", "Open the issue created from this finding");
          fields.url = finding.issueURL;
        } else {
          act("+ Issue", "prFindingIssue", "Create a GitHub issue from this finding");
        }
      }
    }
    act(finding.dismissed ? "Restore" : "\u2715 Dismiss", "prFindingDismiss", finding.dismissed ? "Show it again" : "Not a real problem: hide it and leave it out of the tasks");
    wrap.appendChild(row);
    if (finding.explanation && !finding.dismissed) {
      const p = document.createElement("p");
      p.className = "arch-finding-explanation";
      p.textContent = finding.explanation;
      wrap.appendChild(p);
    }
    return wrap;
  }
  function changeRow(f) {
    const c = palette();
    const wrap = document.createElement("div");
    wrap.className = "arch-change";
    const head = document.createElement("button");
    head.className = "arch-link arch-path";
    const dot = document.createElement("i");
    dot.style.background = f.verdict === "bug" ? c.bad : f.verdict === "concern" ? c.warn : f.verdict === "ok" ? c.ok : c.info;
    head.appendChild(dot);
    head.appendChild(document.createTextNode(f.path + (f.deleted ? "  removed \u2212" + f.deletions : "  +" + f.additions + " \u2212" + f.deletions)));
    head.onclick = function() {
      openPRFile(f.path);
    };
    wrap.appendChild(head);
    if (f.summary) {
      const p = document.createElement("p");
      p.textContent = f.summary;
      wrap.appendChild(p);
    }
    (f.findings || []).forEach(function(finding, index) {
      wrap.appendChild(findingRow(f, finding, index));
    });
    return wrap;
  }
  function renderFilterOptions() {
    const old = el.overlay.querySelector("optgroup[data-ai]");
    if (old) old.remove();
    if (ui.prTab) return;
    const group = document.createElement("optgroup");
    group.label = "AI filters";
    group.setAttribute("data-ai", "1");
    aiFilters().forEach(function(f) {
      const o = document.createElement("option");
      o.value = "ai:" + f.id;
      o.textContent = f.name;
      group.appendChild(o);
    });
    const add = document.createElement("option");
    add.value = "__new__";
    add.textContent = "\uFF0B New filter\u2026";
    group.appendChild(add);
    el.overlay.appendChild(group);
  }
  function renderNewFilterForm() {
    const d = el.details;
    d.textContent = "";
    const h = document.createElement("h4");
    h.textContent = "New AI filter";
    d.appendChild(h);
    const p = document.createElement("p");
    p.className = "arch-muted";
    p.textContent = "A few words are enough. The AI rates every part against it as you zoom in: strong, moderate, weak or none.";
    d.appendChild(p);
    const criterion = document.createElement("textarea");
    criterion.rows = 3;
    criterion.style.width = "100%";
    criterion.placeholder = 'A topic or a question, e.g. "payment flow" or "What handles user sessions?"';
    const name = document.createElement("input");
    name.placeholder = "Name (optional)";
    name.style.width = "100%";
    const create = document.createElement("button");
    create.className = "arch-btn";
    create.textContent = "Create filter";
    create.onclick = function() {
      const text = criterion.value.trim();
      if (!text) return;
      const label = name.value.trim() || (text.length > 28 ? text.slice(0, 28) + "\u2026" : text);
      ui.pendingFilterName = label;
      post("createFilter", { name: label, criterion: text });
    };
    [criterion, name, create].forEach(function(e) {
      e.style.marginTop = "6px";
      d.appendChild(e);
    });
    criterion.focus();
  }
})(window.MVArchitecture);
;
(function(P) {
  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== void 0) node.textContent = text;
    return node;
  }
  function button(text, action, className) {
    const node = element("button", className || "arch-btn", text);
    node.type = "button";
    node.addEventListener("click", action);
    return node;
  }
  function index(graph) {
    return new Map((graph.nodes || []).map(function(node) {
      return [node.id, node];
    }));
  }
  function children(graph, parent) {
    return graph.nodes.filter(function(node) {
      return (node.parent || null) === (parent || null);
    });
  }
  function within(byID, id, ancestor) {
    const seen = /* @__PURE__ */ new Set();
    for (let node = byID.get(id); node && !seen.has(node.id); node = byID.get(node.parent)) {
      if (node.id === ancestor) return true;
      seen.add(node.id);
    }
    return false;
  }
  function ancestors(graph, id) {
    const byID = index(graph), result = [], seen = /* @__PURE__ */ new Set();
    for (let node = byID.get(id); node && !seen.has(node.id); node = byID.get(node.parent)) {
      result.unshift(node);
      seen.add(node.id);
    }
    return result;
  }
  function relations(graph, level, selected) {
    const byID = index(graph), incoming = [], outgoing = [], seen = /* @__PURE__ */ new Set();
    function add(edge, boundary) {
      const from = boundary ? within(byID, edge.from, selected) : edge.from === selected;
      const to = boundary ? within(byID, edge.to, selected) : edge.to === selected;
      if (from && !seen.has("out|" + edge.id)) {
        outgoing.push({ edge, other: edge.to, boundary });
        seen.add("out|" + edge.id);
      }
      if (to && !seen.has("in|" + edge.id)) {
        incoming.push({ edge, other: edge.from, boundary });
        seen.add("in|" + edge.id);
      }
    }
    (level.edges || []).forEach(function(edge) {
      add(edge, false);
    });
    (level.boundary || []).forEach(function(edge) {
      add(edge, true);
    });
    return { incoming, outgoing };
  }
  function bundle(edges) {
    const groups = /* @__PURE__ */ new Map();
    edges.forEach(function(edge) {
      const key = JSON.stringify([edge.from, edge.to, edge.kind]);
      let group = groups.get(key);
      if (!group) {
        group = Object.assign({}, edge, { members: [], labels: [] });
        groups.set(key, group);
      }
      group.members.push(edge.id);
      if (group.labels.indexOf(edge.label) < 0) group.labels.push(edge.label);
    });
    return Array.from(groups.values()).map(function(group) {
      group.label = group.labels.length === 1 ? group.labels[0] : group.labels.length + " conditions";
      group.fullLabel = group.labels.join("; ");
      return group;
    });
  }
  function isStale(scenario, snapshot) {
    const modules = (snapshot.views || []).find(function(view) {
      return view.id === "modules";
    });
    if (!modules) return false;
    const signatures = new Map(modules.nodes.filter(function(node) {
      return node.path;
    }).map(function(node) {
      return [node.path, node.signature];
    }));
    return Object.keys(scenario.signatures || {}).some(function(path) {
      return signatures.get(path) !== scenario.signatures[path];
    });
  }
  function levelKey(scenario, parent) {
    return scenario.id + "|" + (parent || "");
  }
  function sourceKey(scenario, node, source) {
    return scenario.id + "|" + node.id + "|" + source;
  }
  Object.assign(P, {
    element,
    button,
    index,
    children,
    ancestors,
    relations,
    bundle,
    isStale,
    levelKey,
    sourceKey
  });
})(window["MVProcess"] = {});
;
(function(P) {
  function points(section) {
    return [section.startPoint].concat(section.bendPoints || [], [section.endPoint]);
  }
  function path(line) {
    return line.map(function(point, i) {
      return (i ? "L" : "M") + Math.round(point.x * 10) / 10 + " " + Math.round(point.y * 10) / 10;
    }).join(" ");
  }
  function wrap(text, size) {
    const words = String(text || "").split(/\s+/).flatMap(function(word) {
      const pieces = [];
      for (let i = 0; i < word.length; i += size) pieces.push(word.slice(i, i + size));
      return pieces;
    }), lines = [];
    let line = "";
    words.forEach(function(word) {
      if (line && (line + " " + word).length > size) {
        lines.push(line);
        line = "";
      }
      line += (line ? " " : "") + word;
    });
    if (line) lines.push(line);
    if (lines.length > 3) return lines.slice(0, 2).concat(lines[2].slice(0, size - 3) + "...");
    return lines.length ? lines : [""];
  }
  async function layout(level, elk, direction) {
    const down = direction === "DOWN";
    const grouped = P.bundle(level.edges || []);
    const forward = grouped.filter(function(edge) {
      return edge.kind !== "return";
    });
    const returns = grouped.filter(function(edge) {
      return edge.kind === "return";
    });
    const ids = new Set(level.nodes.map(function(node) {
      return node.id;
    }));
    const graph = {
      id: "process",
      layoutOptions: {
        "elk.algorithm": "layered",
        "elk.direction": down ? "DOWN" : "RIGHT",
        "elk.edgeRouting": "ORTHOGONAL",
        "elk.padding": "[top=32,left=32,bottom=32,right=32]",
        "elk.spacing.nodeNode": "38",
        "elk.layered.spacing.nodeNodeBetweenLayers": "58",
        "elk.layered.considerModelOrder.strategy": "NODES_AND_EDGES",
        "elk.layered.crossingMinimization.strategy": "LAYER_SWEEP",
        "elk.layered.nodePlacement.strategy": "NETWORK_SIMPLEX",
        "elk.layered.mergeEdges": "false"
      },
      children: level.nodes.map(function(node) {
        return { id: node.id, width: 156, height: 82 };
      }),
      edges: forward.filter(function(edge) {
        return ids.has(edge.from) && ids.has(edge.to);
      }).map(function(edge) {
        const show = edge.kind === "branch" || edge.kind === "error" || edge.kind === "parallel";
        const lines = wrap(edge.label, 18);
        return {
          id: edge.id,
          sources: [edge.from],
          targets: [edge.to],
          labels: show ? [{
            id: edge.id + "-label",
            text: edge.label,
            width: Math.min(124, Math.max.apply(null, lines.map(function(line) {
              return line.length;
            })) * 6.5 + 8),
            height: lines.length * 14 + 4
          }] : []
        };
      })
    };
    const placed = await elk.layout(graph);
    const before = Math.ceil(returns.length / 2), after = Math.floor(returns.length / 2);
    const paddingBefore = before ? before * 34 + 20 : 0;
    const paddingAfter = after ? after * 34 + 20 : 0;
    const shiftX = down ? paddingBefore : 0, shiftY = down ? 0 : paddingBefore;
    const positions = /* @__PURE__ */ new Map();
    (placed.children || []).forEach(function(node) {
      if (![node.x, node.y, node.width, node.height].every(Number.isFinite)) throw new Error("Invalid process layout");
      positions.set(node.id, { x: node.x + shiftX, y: node.y + shiftY, width: node.width, height: node.height });
    });
    const edges = [];
    (placed.edges || []).forEach(function(edge) {
      const original = grouped.find(function(item) {
        return item.id === edge.id;
      });
      if (!original || !edge.sections || !edge.sections.length) return;
      const sections = edge.sections.map(function(section) {
        return points(section).map(function(point) {
          return { x: point.x + shiftX, y: point.y + shiftY };
        });
      });
      const label = edge.labels && edge.labels[0];
      edges.push(Object.assign({}, original, {
        sections,
        labelBox: label ? {
          x: label.x + shiftX,
          y: label.y + shiftY,
          width: label.width,
          height: label.height,
          lines: wrap(original.label, 18)
        } : null
      }));
    });
    returns.forEach(function(edge, i) {
      const a = positions.get(edge.from), b = positions.get(edge.to);
      if (!a || !b) return;
      const first = i % 2 === 0, slot = Math.floor(i / 2), track = first ? paddingBefore - 18 - slot * 34 : paddingBefore + (down ? placed.width : placed.height) + 18 + slot * 34;
      let route, labelBox;
      if (down) {
        const ax = a.x + a.width / 2, bx = b.x + b.width / 2;
        const sy = a.y + a.height, ty = b.y;
        route = [
          { x: ax, y: sy },
          { x: ax, y: sy + 16 },
          { x: track, y: sy + 16 },
          { x: track, y: ty - 16 },
          { x: bx, y: ty - 16 },
          { x: bx, y: ty }
        ];
        labelBox = { x: track - 12, y: (sy + ty) / 2 - 9, width: 24, height: 18, lines: ["R" + (i + 1)] };
      } else {
        const ay = a.y + a.height / 2, by = b.y + b.height / 2;
        const sx = a.x + a.width, tx = b.x;
        route = [
          { x: sx, y: ay },
          { x: sx + 16, y: ay },
          { x: sx + 16, y: track },
          { x: tx - 16, y: track },
          { x: tx - 16, y: by },
          { x: tx, y: by }
        ];
        labelBox = { x: (sx + tx) / 2 - 12, y: track - 9, width: 24, height: 18, lines: ["R" + (i + 1)] };
      }
      edges.push(Object.assign({}, edge, { sections: [route], labelBox, returnName: "R" + (i + 1) }));
    });
    return {
      nodes: positions,
      edges,
      width: placed.width + (down ? paddingBefore + paddingAfter : 0),
      height: placed.height + (down ? 0 : paddingBefore + paddingAfter),
      direction: down ? "DOWN" : "RIGHT"
    };
  }
  Object.assign(P, { layout, path });
})(window["MVProcess"]);
;
(function(P) {
  function makePanel(parent, actions) {
    const host = P.element("section", "process-inspector");
    host.setAttribute("aria-label", "Selected block code and explanation");
    const heading = P.element("div", "process-selection");
    const title = P.element("h3");
    const symbol = P.element("code");
    const locate = P.button("Locate block", actions.locate);
    heading.append(title, symbol, locate);
    const columns = P.element("div", "process-columns");
    const codePanel = P.element("section", "process-code-panel");
    const codeHead = P.element("div", "process-panel-head");
    const open = P.button("Open full file", function() {
      if (selectedSnippet) actions.open(selectedSnippet);
    });
    codeHead.append(P.element("h4", "", "Code excerpt"), open);
    const tabs = P.element("div", "process-sources");
    tabs.setAttribute("role", "group");
    tabs.setAttribute("aria-label", "Source excerpts");
    const path = P.element("div", "process-source-path");
    const status = P.element("div", "process-source-status");
    status.setAttribute("role", "status");
    const codeHost = P.element("div", "process-code-host");
    codePanel.append(codeHead, tabs, path, status, codeHost);
    const explanationPanel = P.element("section", "process-explain-panel");
    const explainHead = P.element("div", "process-panel-head");
    explainHead.append(P.element("h4", "", "Explain"), P.element("span", "arch-muted", "For the selected block and excerpt"));
    const explanation = P.element("div", "process-explanation");
    explanation.setAttribute("aria-live", "polite");
    explanationPanel.append(explainHead, explanation);
    columns.append(codePanel, explanationPanel);
    const related = P.element("div", "process-related");
    host.append(heading, columns, related);
    parent.append(host);
    let viewer = null, viewerGeneration = 0, codeStamp = "", tabsStamp = "", selectedSnippet = null;
    function showCode(snippet, key) {
      const stamp = key + "|" + (snippet ? snippet.path + "|" + snippet.language + "|" + snippet.line + "|" + snippet.code : "");
      if (stamp === codeStamp) return;
      codeStamp = stamp;
      const ticket = ++viewerGeneration;
      if (!snippet) {
        if (viewer) viewer.setDoc("", "", 1);
        else codeHost.textContent = "";
        return;
      }
      const loader = window["MVLoadCode"];
      if (!loader) {
        codeHost.textContent = snippet.code;
        return;
      }
      loader().then(function() {
        if (ticket !== viewerGeneration) return;
        if (!viewer) {
          codeHost.textContent = "";
          viewer = window["MVCode"].create(codeHost, {
            doc: snippet.code,
            language: snippet.language,
            startLine: snippet.line,
            dark: document.documentElement.getAttribute("data-theme") === "dark"
          });
        } else viewer.setDoc(snippet.code, snippet.language, snippet.line);
      }).catch(function() {
        if (ticket === viewerGeneration) {
          codeHost.textContent = "";
          codeHost.append(P.element("pre", "", snippet.code));
        }
      });
    }
    function render(context) {
      const node = context.node;
      host.hidden = !node;
      if (!node) {
        selectedSnippet = null;
        showCode(null, "empty");
        return;
      }
      const scenario = context.scenario, source = (node.sources || [])[context.source];
      const key = P.sourceKey(scenario, node, context.source), state2 = context.payload.processState || {};
      const error = (state2.errors || {})[key];
      const snippet = error ? null : (state2.snippets || {})[key];
      selectedSnippet = snippet || null;
      title.textContent = node.title;
      symbol.textContent = node.symbol || "";
      symbol.hidden = !node.symbol;
      open.disabled = !snippet;
      const nextTabs = scenario.id + "|" + node.id + "|" + JSON.stringify(node.sources || []);
      if (tabsStamp !== nextTabs) {
        tabsStamp = nextTabs;
        tabs.textContent = "";
        (node.sources || []).forEach(function(item, i) {
          const label = item.path.split("/").pop() + ":" + item.line;
          const tab = P.button(label, function() {
            actions.source(i);
          }, "process-source-tab");
          tab.title = item.path + ":" + item.line + "-" + item.endLine;
          tabs.append(tab);
        });
      }
      Array.from(tabs.children).forEach(function(tab, i) {
        tab.setAttribute("aria-pressed", String(i === context.source));
      });
      path.textContent = source ? source.path + ":" + source.line + "-" + source.endLine : "External participant";
      const stale = snippet && snippet.stale || P.isStale(scenario, context.payload.snapshot || {});
      status.classList.toggle("process-warning", !!stale || !!error);
      status.textContent = error || (stale ? "Source changed. Refresh the process map to update this explanation." : !source ? "This participant has no source excerpt." : state2.loading === key ? snippet ? "Checking source..." : "Loading source..." : snippet && snippet.truncated ? "Excerpt shortened. Open the full file to read all cited code." : "Read-only source");
      showCode(snippet, key);
      explanation.textContent = "";
      const fields = [
        ["Purpose", node.explanation],
        ["This excerpt", source && source.note],
        ["Input", node.input],
        ["Output and continuation", node.output]
      ];
      fields.forEach(function(pair) {
        if (!pair[1]) return;
        const part = P.element("div", "process-explain-item");
        part.append(P.element("h5", "", pair[0]), P.element("p", "", pair[1]));
        explanation.append(part);
      });
      related.textContent = "";
      const connections = P.relations(scenario.graph, context.level || { edges: [], boundary: [] }, node.id);
      const byID = P.index(scenario.graph);
      [["Incoming", connections.incoming], ["Outgoing", connections.outgoing]].forEach(function(pair) {
        const section = P.element("div", "process-connection-list");
        section.append(P.element("h5", "", pair[0] + " connections"));
        if (!pair[1].length) section.append(P.element("span", "arch-muted", "No connection at this level"));
        pair[1].forEach(function(item) {
          const target = byID.get(item.other);
          const link = P.button(
            (target ? target.title : item.other) + ": " + item.edge.label,
            function() {
              actions.navigate(item.other);
            },
            "process-reference"
          );
          link.classList.toggle("is-return", item.edge.kind === "return");
          if (item.boundary) link.title = "Connection outside the current group";
          section.append(link);
        });
        related.append(section);
      });
    }
    return { render, element: host };
  }
  Object.assign(P, { makePanel });
})(window["MVProcess"]);
;
(function(P) {
  let nextID = 0;
  function svg(tag, attributes) {
    const node = document.createElementNS("http://www.w3.org/2000/svg", tag);
    Object.keys(attributes || {}).forEach(function(key) {
      node.setAttribute(key, String(attributes[key]));
    });
    return node;
  }
  function makeViewport(parent, actions) {
    const viewport = P.element("div", "process-viewport");
    viewport.setAttribute("aria-label", "Process graph. Drag the background to pan. Use the zoom controls to magnify.");
    const scene = P.element("div", "process-scene");
    const paths = svg("svg", { class: "process-edges", "aria-hidden": "true" });
    const nodes = P.element("div", "process-nodes");
    scene.append(paths, nodes);
    viewport.append(scene);
    parent.append(viewport);
    const prefix = "process-arrow-" + ++nextID;
    let drawing = null, pose = { x: 0, y: 0, zoom: 1 }, drag = null;
    const nodeElements = /* @__PURE__ */ new Map(), edgeElements = [];
    function apply() {
      scene.style.transform = "translate(" + pose.x + "px," + pose.y + "px) scale(" + pose.zoom + ")";
      actions.changed(pose.zoom);
    }
    function zoom(value, point) {
      const target = Math.max(0.12, Math.min(3, value));
      const center = point || { x: viewport.clientWidth / 2, y: viewport.clientHeight / 2 };
      const factor = target / pose.zoom;
      pose.x = center.x - (center.x - pose.x) * factor;
      pose.y = center.y - (center.y - pose.y) * factor;
      pose.zoom = target;
      apply();
    }
    function focus(id) {
      const node = drawing && drawing.nodes.get(id);
      if (!node) return;
      pose.x = viewport.clientWidth / 2 - (node.x + node.width / 2) * pose.zoom;
      pose.y = viewport.clientHeight / 2 - (node.y + node.height / 2) * pose.zoom;
      apply();
    }
    function fit(readable) {
      if (!drawing || !viewport.clientWidth || !viewport.clientHeight) return;
      const value = Math.min((viewport.clientWidth - 36) / drawing.width, (viewport.clientHeight - 36) / drawing.height, 1.3);
      pose.zoom = Math.max(readable ? 0.7 : 0.12, value);
      pose.x = (viewport.clientWidth - drawing.width * pose.zoom) / 2;
      pose.y = (viewport.clientHeight - drawing.height * pose.zoom) / 2;
      apply();
    }
    function setDrawing(next, graph, savedPose, selected) {
      drawing = next;
      scene.style.width = next.width + "px";
      scene.style.height = next.height + "px";
      paths.setAttribute("width", String(next.width));
      paths.setAttribute("height", String(next.height));
      paths.setAttribute("viewBox", "0 0 " + next.width + " " + next.height);
      paths.textContent = "";
      nodes.textContent = "";
      nodeElements.clear();
      edgeElements.length = 0;
      const definitions = svg("defs");
      ["normal", "selected", "return"].forEach(function(kind) {
        const marker = svg("marker", {
          id: prefix + "-" + kind,
          viewBox: "0 0 8 8",
          refX: 7,
          refY: 4,
          markerWidth: 7,
          markerHeight: 7,
          orient: "auto"
        });
        marker.append(svg("path", { d: "M0 0 L8 4 L0 8 Z", class: "process-arrow-" + kind }));
        definitions.append(marker);
      });
      paths.append(definitions);
      next.edges.forEach(function(edge) {
        const group = svg("g", { class: "process-edge-group" });
        const caption = svg("title");
        caption.textContent = edge.fullLabel || edge.label;
        group.append(caption);
        const strokes = [];
        edge.sections.forEach(function(section, i) {
          const d = P.path(section);
          if (edge.kind === "return") group.append(svg("path", { d, class: "process-return-halo" }));
          const stroke = svg("path", { d, class: "process-edge" + (edge.kind === "return" ? " is-return" : "") });
          if (i === edge.sections.length - 1) stroke.setAttribute("marker-end", "url(#" + prefix + "-" + (edge.kind === "return" ? "return" : "normal") + ")");
          group.append(stroke);
          strokes.push(stroke);
        });
        if (edge.labelBox) {
          const box = edge.labelBox;
          group.append(svg("rect", { x: box.x, y: box.y, width: box.width, height: box.height, rx: 3, class: "process-edge-label-bg" }));
          const text = svg("text", {
            x: box.x + box.width / 2,
            y: box.y + 12,
            "text-anchor": "middle",
            class: "process-edge-label" + (edge.kind === "return" ? " is-return" : "")
          });
          box.lines.forEach(function(line, i) {
            const span = svg("tspan", { x: box.x + box.width / 2, dy: i ? 14 : 0 });
            span.textContent = line;
            text.append(span);
          });
          group.append(text);
        }
        paths.append(group);
        edgeElements.push({ group, strokes, edge });
      });
      const byID = P.index(graph);
      next.nodes.forEach(function(at, id) {
        const node = byID.get(id);
        if (!node) return;
        const count = P.children(graph, id).length;
        const button = P.button("", function() {
          actions.select(id);
        }, "process-node");
        const rawKind = node.kind || (count ? "group" : "action");
        const kind = rawKind.charAt(0).toUpperCase() + rawKind.slice(1);
        button.append(
          P.element("span", "process-node-kind", kind + (count ? " \xB7 " + count + " steps" : "")),
          P.element("span", "process-node-title", node.title)
        );
        button.dataset.processNode = id;
        button.title = node.title + (count ? "\nDouble-click to open the group" : "");
        button.setAttribute("aria-label", node.title + (count ? ", group with " + count + " steps" : ""));
        Object.assign(button.style, { left: at.x + "px", top: at.y + "px", width: at.width + "px", height: at.height + "px" });
        button.addEventListener("dblclick", function(event) {
          if (!count) return;
          event.preventDefault();
          event.stopPropagation();
          actions.openGroup(id);
        });
        nodes.append(button);
        nodeElements.set(id, button);
      });
      if (savedPose) {
        pose = Object.assign({}, savedPose);
        apply();
      } else {
        fit(true);
        if (pose.zoom <= 0.7 && selected) {
          focus(selected);
          const entry = next.nodes.get(selected);
          if (entry && !next.edges.some(function(edge) {
            return edge.to === selected && edge.kind !== "return";
          })) {
            if (next.direction === "DOWN") pose.y = 24 - entry.y * pose.zoom;
            else pose.x = 24 - entry.x * pose.zoom;
            apply();
          }
        }
      }
    }
    function highlight(selected, neighborsOnly) {
      const neighbors = /* @__PURE__ */ new Set([selected]);
      edgeElements.forEach(function(item) {
        if (item.edge.from === selected) neighbors.add(item.edge.to);
        if (item.edge.to === selected) neighbors.add(item.edge.from);
      });
      nodeElements.forEach(function(node, id) {
        node.setAttribute("aria-pressed", String(id === selected));
        node.classList.toggle("is-muted", !!neighborsOnly && !neighbors.has(id));
      });
      edgeElements.forEach(function(item) {
        const active = item.edge.from === selected || item.edge.to === selected;
        item.group.style.display = neighborsOnly && !active ? "none" : "";
        item.strokes.forEach(function(stroke, i) {
          stroke.classList.toggle("is-selected", active);
          if (i === item.strokes.length - 1) stroke.setAttribute("marker-end", "url(#" + prefix + "-" + (item.edge.kind === "return" ? "return" : active ? "selected" : "normal") + ")");
        });
      });
    }
    viewport.addEventListener("wheel", function(event) {
      if (!drawing) return;
      event.preventDefault();
      const bounds = viewport.getBoundingClientRect();
      if (event.ctrlKey || event.metaKey) zoom(pose.zoom * Math.exp(-event.deltaY * 8e-3), { x: event.clientX - bounds.left, y: event.clientY - bounds.top });
      else {
        pose.x -= event.deltaX;
        pose.y -= event.deltaY;
        apply();
      }
    }, { passive: false });
    viewport.addEventListener("pointerdown", function(event) {
      if (event.button !== 0 || event.target.closest("button")) return;
      drag = { x: event.clientX - pose.x, y: event.clientY - pose.y };
      viewport.setPointerCapture(event.pointerId);
      viewport.classList.add("is-dragging");
    });
    viewport.addEventListener("pointermove", function(event) {
      if (!drag) return;
      pose.x = event.clientX - drag.x;
      pose.y = event.clientY - drag.y;
      apply();
    });
    function endDrag() {
      drag = null;
      viewport.classList.remove("is-dragging");
    }
    viewport.addEventListener("pointerup", endDrag);
    viewport.addEventListener("pointercancel", endDrag);
    return {
      element: viewport,
      setDrawing,
      highlight,
      fit: function() {
        fit(false);
      },
      zoom: function(factor) {
        zoom(pose.zoom * factor);
      },
      actualSize: function(id) {
        zoom(1);
        focus(id);
      },
      focus,
      pose: function() {
        return Object.assign({}, pose);
      },
      clear: function() {
        drawing = null;
        paths.textContent = "";
        nodes.textContent = "";
      }
    };
  }
  Object.assign(P, { makeViewport });
})(window["MVProcess"]);
;
(function(P, A) {
  if (!A.ready) return;
  const root = document.getElementById("arch-process");
  const main = root && root.parentElement;
  if (!root || !main) return;
  const form = P.element("form", "process-question");
  const question = P.element("textarea");
  question.rows = 2;
  question.maxLength = 4e3;
  question.setAttribute("aria-label", "Process to trace");
  question.placeholder = "How is a request handled, including parallel work, refusals and retries?";
  const submit = P.button("Trace process", function() {
    requestTrace();
  });
  const stop = P.button("Stop", function() {
    A.post("cancelAnalysis");
  });
  stop.hidden = true;
  const picker = P.element("select");
  picker.setAttribute("aria-label", "Saved process");
  const formActions = P.element("div", "process-question-actions");
  formActions.append(picker, submit, stop);
  form.append(question, formActions);
  const scopeInfo = P.element("details", "process-scope-info");
  const scopeTitle = P.element("summary", "", "Process context");
  const takeaway = P.element("p"), omitted = P.element("p");
  scopeInfo.append(scopeTitle, takeaway, omitted);
  const tools = P.element("div", "process-tools");
  const breadcrumbs = P.element("nav", "process-breadcrumbs");
  breadcrumbs.setAttribute("aria-label", "Process hierarchy");
  const direction = P.element("select");
  direction.setAttribute("aria-label", "Flow direction");
  [["RIGHT", "Left to right"], ["DOWN", "Top to bottom"]].forEach(function(item) {
    const option = P.element("option", "", item[1]);
    option.value = item[0];
    direction.append(option);
  });
  const zoomText = P.element("span", "process-zoom", "100%");
  const controls = P.element("div", "process-map-controls");
  const zoomOut = P.button("-", function() {
    surface.zoom(1 / 1.2);
  });
  zoomOut.setAttribute("aria-label", "Zoom out");
  const zoomIn = P.button("+", function() {
    surface.zoom(1.2);
  });
  zoomIn.setAttribute("aria-label", "Zoom in");
  const fit = P.button("Fit", function() {
    surface.fit();
  });
  const actual = P.button("1:1", function() {
    surface.actualSize(selected);
  });
  const expand = P.button("Expand map", function() {
    const expanded = root.classList.toggle("process-map-expanded");
    expand.textContent = expanded ? "Compact map" : "Expand map";
  });
  controls.append(direction, zoomOut, zoomText, zoomIn, fit, actual, expand);
  tools.append(breadcrumbs, controls);
  const context = P.element("div", "process-context");
  const summary = P.element("span", "arch-muted");
  const focusLabel = P.element("label", "arch-check");
  const focus = P.element("input");
  focus.type = "checkbox";
  focusLabel.append(focus, document.createTextNode("Only neighboring connections"));
  const openGroup = P.button("Open group", function() {
    drill(selected);
  });
  context.append(summary, focusLabel, openGroup);
  const canvas = P.element("div", "process-map");
  const message = P.element("p", "process-map-message");
  message.setAttribute("role", "status");
  const returns = P.element("div", "process-returns");
  const caption = P.element("div", "process-map-caption");
  caption.append(
    P.element("span", "arch-muted", "Drag to pan. Pinch or Ctrl+wheel to zoom. Double-click a group to enter."),
    P.button("Code + Explain", function() {
      panel.element.scrollIntoView({ block: "start" });
    })
  );
  root.append(form, scopeInfo, tools, context, message, canvas, returns, caption);
  let payload = {}, project = null, activeID = null, parent = null, selected = null, source = 0;
  let requestedSource = "", savedChoices = "", savedVersion = "", awaiting = false, active = false;
  let renderedKey = "", pendingKey = "", layoutToken = 0;
  const layouts = /* @__PURE__ */ new Map(), poses = /* @__PURE__ */ new Map(), scopeSelections = /* @__PURE__ */ new Map(), pendingLevels = /* @__PURE__ */ new Set();
  const surface = P.makeViewport(canvas, {
    select,
    openGroup: drill,
    changed: function(value) {
      zoomText.textContent = Math.round(value * 100) + "%";
    }
  });
  const panel = P.makePanel(root, {
    source: function(index) {
      source = index;
      requestedSource = "";
      render(payload);
    },
    navigate,
    locate: function() {
      surface.focus(selected);
      canvas.scrollIntoView({ block: "nearest" });
    },
    open: function(snippet) {
      A.post("openFile", { path: snippet.path, line: snippet.line, endLine: snippet.requestedEndLine });
    }
  });
  function scenarios() {
    return payload.snapshot && payload.snapshot.processGraphs || [];
  }
  function canTrace() {
    const modules = payload.snapshot && (payload.snapshot.views || []).find(function(view) {
      return view.id === "modules";
    });
    return !!modules && modules.nodes.some(function(node) {
      return node.kind === "file" && node.language !== "markdown";
    });
  }
  function current() {
    return scenarios().find(function(item) {
      return item.id === activeID;
    }) || null;
  }
  function remember() {
    if (renderedKey) poses.set(renderedKey, surface.pose());
    if (activeID) scopeSelections.set(activeID + "|" + (parent || ""), selected);
  }
  function reset() {
    remember();
    project = null;
    activeID = null;
    parent = null;
    selected = null;
    source = 0;
    requestedSource = "";
    savedChoices = "";
    savedVersion = "";
    awaiting = false;
    renderedKey = "";
    pendingKey = "";
    layoutToken += 1;
    layouts.clear();
    poses.clear();
    scopeSelections.clear();
    pendingLevels.clear();
    surface.clear();
  }
  function requestTrace() {
    if (payload.busy || !canTrace() || !question.value.trim()) return;
    awaiting = true;
    A.post("traceProcess", { question: question.value.trim() });
  }
  function select(id) {
    selected = id;
    source = 0;
    const scenario = current();
    const key = scenario && P.sourceKey(scenario, { id }, 0);
    if (key && ((payload.processState || {}).errors || {})[key]) requestedSource = "";
    render(payload);
  }
  function setScope(next, selection) {
    remember();
    parent = next || null;
    source = 0;
    requestedSource = "";
    pendingKey = "";
    layoutToken += 1;
    selected = selection || scopeSelections.get(activeID + "|" + (parent || "")) || null;
    render(payload);
  }
  function drill(id) {
    const scenario = current();
    if (scenario && P.children(scenario.graph, id).length) setScope(id, null);
  }
  function navigate(id) {
    const scenario = current(), node = scenario && P.index(scenario.graph).get(id);
    if (!node) return;
    if ((node.parent || null) !== parent) setScope(node.parent || null, id);
    else {
      select(id);
      surface.focus(id);
    }
  }
  function draw(scenario, level) {
    const key = scenario.id + "|" + scenario.createdAt + "|" + (parent || "") + "|" + direction.value;
    const known = layouts.get(key);
    if (known) {
      if (renderedKey !== key) {
        remember();
        surface.setDrawing(known, scenario.graph, poses.get(key), selected);
        renderedKey = key;
        returns.textContent = "";
        known.edges.filter(function(edge) {
          return edge.returnName;
        }).forEach(function(edge) {
          returns.append(P.button(edge.returnName + ": " + edge.fullLabel, function() {
            navigate(edge.from);
          }, "process-return-link"));
        });
      }
      message.hidden = true;
      surface.highlight(selected, focus.checked);
      return;
    }
    if (pendingKey === key) return;
    pendingKey = key;
    const ticket = ++layoutToken;
    message.hidden = false;
    message.textContent = "Laying out the process...";
    remember();
    surface.clear();
    renderedKey = "";
    returns.textContent = "";
    A.loadLibraries().then(function() {
      return P.layout(level, new window["ELK"](), direction.value);
    }).then(function(drawing) {
      if (ticket !== layoutToken) return;
      layouts.set(key, drawing);
      while (layouts.size > 32) layouts.delete(layouts.keys().next().value);
      pendingKey = "";
      if (active && current() && current().id === scenario.id) draw(scenario, level);
    }).catch(function(error) {
      if (ticket !== layoutToken) return;
      pendingKey = "";
      message.hidden = false;
      message.textContent = "The process layout could not be drawn: " + error.message;
    });
  }
  function render(next) {
    payload = next || {};
    active = true;
    root.hidden = false;
    main.classList.add("process-mode");
    if (project !== payload.root) {
      reset();
      project = payload.root;
      question.value = "";
    }
    const saved = scenarios();
    const version = saved.map(function(item) {
      return item.id + "|" + item.createdAt;
    }).join(";");
    if (!saved.some(function(item) {
      return item.id === activeID;
    }) || awaiting && version !== savedVersion) {
      remember();
      const latest = saved[saved.length - 1];
      activeID = latest ? latest.id : null;
      parent = null;
      selected = null;
      source = 0;
      requestedSource = "";
      awaiting = false;
    }
    savedVersion = version;
    const scenario = current();
    scopeInfo.hidden = !scenario;
    takeaway.textContent = scenario ? scenario.graph.takeaway : "";
    omitted.textContent = scenario && scenario.graph.omitted ? "Not mapped: " + scenario.graph.omitted : "";
    omitted.hidden = !omitted.textContent;
    if (savedChoices !== version) {
      picker.textContent = "";
      savedChoices = version;
      saved.forEach(function(item) {
        const option = P.element("option", "", item.graph.title);
        option.value = item.id;
        picker.append(option);
      });
    }
    picker.hidden = saved.length < 2;
    picker.value = activeID || "";
    if (!question.value && scenario) question.value = scenario.graph.question;
    submit.disabled = !!payload.busy || !canTrace() || !question.value.trim();
    submit.title = canTrace() ? "Read the source again and trace this process" : "Scan a project with source files first";
    submit.textContent = (payload.processState || {}).tracing ? "Tracing..." : "Trace process";
    stop.hidden = !(payload.processState || {}).tracing;
    breadcrumbs.textContent = "";
    breadcrumbs.append(P.button(scenario ? scenario.graph.title : "Process", function() {
      const first = scenario && P.ancestors(scenario.graph, parent)[0];
      setScope(null, first ? first.id : null);
    }, "arch-crumb"));
    if (!scenario) {
      canvas.hidden = true;
      returns.textContent = "";
      panel.render({ node: null });
      message.hidden = false;
      message.textContent = canTrace() ? "Describe a process to map its branches, joins and returns from source code." : "Scan a project with source files to build a process map.";
      summary.textContent = "Source interpretation";
      openGroup.hidden = true;
      return;
    }
    canvas.hidden = false;
    P.ancestors(scenario.graph, parent).forEach(function(node2) {
      breadcrumbs.append(P.element("span", "arch-muted", "/"), P.button(node2.title, function() {
        setScope(node2.id, null);
      }, "arch-crumb"));
    });
    const state2 = payload.processState || {}, key = P.levelKey(scenario, parent);
    const level = (state2.levels || {})[key];
    if (level) pendingLevels.delete(key);
    else if (!pendingLevels.has(key)) {
      pendingLevels.add(key);
      A.post("processLevel", { scenario: scenario.id, parent });
    }
    const byID = P.index(scenario.graph);
    if (level && !level.nodes.some(function(node2) {
      return node2.id === selected;
    })) {
      const first = level.nodes.find(function(node2) {
        return node2.kind === "entry";
      }) || level.nodes[0];
      selected = first ? first.id : null;
    }
    const node = byID.get(selected);
    openGroup.hidden = !node || !P.children(scenario.graph, node.id).length;
    openGroup.textContent = node ? "Open group (" + P.children(scenario.graph, node.id).length + ")" : "Open group";
    summary.textContent = (P.isStale(scenario, payload.snapshot) ? "Source changed. " : "") + (level ? level.nodes.length + " blocks on this level, " + level.edges.length + " transitions. " : "") + "Source interpretation";
    if (level && level.nodes.length) draw(scenario, level);
    else {
      remember();
      surface.clear();
      renderedKey = "";
      message.hidden = false;
      message.textContent = level ? "This group has no internal steps." : "Opening the group...";
    }
    surface.highlight(selected, focus.checked);
    panel.render({ node, scenario, payload, level, source });
    if (node && (node.sources || [])[source]) {
      const stamp = P.sourceKey(scenario, node, source) + "|" + scenario.createdAt + "|" + payload.snapshot.scannedAt;
      if (requestedSource !== stamp) {
        requestedSource = stamp;
        A.post("processSource", { scenario: scenario.id, node: node.id, index: source });
      }
    }
  }
  question.addEventListener("input", function() {
    submit.disabled = !!payload.busy || !canTrace() || !question.value.trim();
  });
  form.addEventListener("submit", function(event) {
    event.preventDefault();
    requestTrace();
  });
  picker.addEventListener("change", function() {
    remember();
    activeID = picker.value;
    parent = null;
    selected = null;
    source = 0;
    requestedSource = "";
    const scenario = current();
    question.value = scenario ? scenario.graph.question : "";
    render(payload);
  });
  direction.addEventListener("change", function() {
    remember();
    render(payload);
  });
  focus.addEventListener("change", function() {
    surface.highlight(selected, focus.checked);
  });
  Object.assign(A, { process: {
    render,
    fit: surface.fit,
    reset,
    hide: function() {
      active = false;
      remember();
      root.hidden = true;
      main.classList.remove("process-mode");
    },
    ask: function() {
      question.focus();
    }
  } });
})(window["MVProcess"], window["MVArchitecture"]);
;
(function(A) {
  if (!A.ready) return;
  const {
    autoExpand,
    buildFullPRView,
    buildPRView,
    codeViews,
    container,
    currentFilter,
    currentView,
    el,
    ensureCy,
    formatCount,
    hiddenTags,
    hideCodeSequence,
    indexView,
    isAIFilter,
    isBook,
    isHidden,
    isOperationRunning,
    isSearch,
    loadLibraries,
    overlayApplies,
    post,
    render,
    renderDeployButton,
    renderDetails,
    renderEmpty,
    renderFilterOptions,
    renderNewFilterForm,
    restyle,
    showCodeSequence,
    stateKey,
    stylesheet,
    ui,
    visibleOperations
  } = A;
  Object.assign(A, { askBook, renderToolbar });
  function renderToolbar() {
    const p = ui.payload || {};
    const temp = (p.filters || []).find(function(f) {
      return f.id.indexOf("tmp-") === 0;
    });
    if (ui.pendingTemp && temp && temp.criterion === ui.pendingTemp) {
      ui.overlay = "ai:" + temp.id;
      ui.pendingTemp = null;
    }
    if (!temp && ui.overlay.indexOf("ai:tmp-") === 0) ui.overlay = "none";
    if (p.activateFilter && p.activateFilter !== ui.activatedFilter) {
      ui.activatedFilter = p.activateFilter;
      const id = p.activateFilter.split("|")[0];
      if ((p.filters || []).some(function(f) {
        return f.id === id;
      })) ui.overlay = "ai:" + id;
      if ((p.understandingAnswers || {})[id]) {
        setDetailsHidden(false, false);
        el.details.scrollTop = 0;
        ui.selected = null;
        ui.selectedEdge = null;
        ui.onlyFlagged = false;
      }
    }
    el.tempFilter.querySelector("button").hidden = !temp;
    if (temp && document.activeElement !== el.tempFilter.querySelector("input")) el.tempFilter.querySelector("input").value = temp.criterion;
    if (ui.pendingFilterName) {
      const made = (p.filters || []).find(function(f) {
        return f.name === ui.pendingFilterName;
      });
      if (made) {
        ui.overlay = "ai:" + made.id;
        ui.pendingFilterName = null;
      }
    }
    if (ui.prTab && ui.overlay.indexOf("ai:") === 0) ui.overlay = "pr";
    renderFilterOptions();
    el.views.forEach(function(b) {
      b.classList.toggle("on", b.getAttribute("data-arch-view") === ui.view);
    });
    const codeOnly = { coverage: 1, tests: 1, bugs: 1, complexity: 1, pr: 1 };
    Array.prototype.forEach.call(el.overlay.options, function(o) {
      if (!codeOnly[o.value]) return;
      o.disabled = isBook();
      o.title = isBook() ? "About code; in the Book use Importance, an AI filter, Freshness or Size" : "";
    });
    el.overlay.value = ui.overlay;
    el.overlay.disabled = ui.view === "deployment" && !isSearch(currentFilter());
    const ask = el.tempFilter.querySelector("input");
    ask.placeholder = isBook() ? "\u26A1 Ask the book, e.g. how is a release published?" : "\u26A1 Ask the project, e.g. how is a plant identified?";
    el.tempFilter.title = "Ask a question: the answer (what, why, how, where it comes from) with its sources appears on the right; the documents, sections and files it rests on turn red";
    el.flagged.checked = ui.onlyFlagged;
    el.flagged.parentElement.hidden = !overlayApplies() || ui.overlay === "size";
    el.hide.hidden = !codeViews[ui.view];
    el.hide.value = Array.from(hiddenTags()).join(",");
    const sources = p.prSources || [];
    const selected = p.pr ? p.pr.source.id : "";
    el.prSource.textContent = "";
    const placeholder = document.createElement("option");
    placeholder.value = "";
    placeholder.textContent = sources.length ? "Choose a change\u2026" : "No git changes found";
    el.prSource.appendChild(placeholder);
    sources.forEach(function(s) {
      const o = document.createElement("option");
      o.value = s.id;
      o.textContent = s.title;
      if (s.id === selected) o.selected = true;
      el.prSource.appendChild(o);
    });
    const prTab = p.mode === "pr";
    const prMode = prTab || overlayApplies() && ui.overlay === "pr";
    el.views[0].parentElement.hidden = prTab;
    el.overlay.hidden = ui.view === "process";
    el.tempFilter.hidden = prTab || ui.view === "process";
    el.prMap.hidden = !prTab;
    Array.prototype.forEach.call(el.prMap.querySelectorAll("[data-arch-pr-map]"), function(b) {
      b.classList.toggle("on", b.getAttribute("data-arch-pr-map") === ui.prMap);
    });
    el.prDate.hidden = p.mode === "folder" || ui.view === "process";
    el.hide.hidden = el.hide.hidden || prTab;
    el.flagged.parentElement.hidden = el.flagged.parentElement.hidden || prTab;
    el.prOpen.hidden = prTab;
    el.analyzePR.hidden = !prTab;
    el.prNumber.hidden = !prTab;
    el.analyzePR.disabled = !p.pr || !!(p.pr && p.pr.analyzing);
    el.analyzePR.textContent = p.pr && p.pr.analyzing ? "Analysing\u2026" : p.pr && p.pr.analysis ? "Analyze again" : "Analyze PR";
    el.prSource.hidden = !prMode;
    el.review.hidden = !prMode;
    el.review.disabled = !p.pr || p.busy;
    el.review.textContent = p.pr && p.pr.reviewed ? "Review again" : "Review with AI";
    el.review.title = p.pr && p.pr.reviewed ? "Reload the change as it is now and review it again (no cached answers)" : "AI review of every changed file";
    el.codeTrace.hidden = ui.view !== "code" || p.mode === "pr";
    el.analyze.hidden = ui.view === "process";
    el.detailsToggle.hidden = ui.view === "process";
    renderHistory();
    el.analyze.disabled = !!p.busy || !p.snapshot;
    el.analyze.textContent = ui.view === "code" ? "Refresh" : "Analyze";
    el.analyze.title = ui.view !== "code" ? "Describe modules and map deployment with the selected AI assistant" : p.automaticAnalysis === false ? "Analyze the code of this folder again now: components and layers (traces stay manual)" : "Analyze the code again now: components, layers and automatic scenarios (manual traces are kept)";
    el.rescan.disabled = !!p.busy;
    renderDeployButton();
    const codeOverlayInBook = isBook() && codeOnly[ui.overlay] ? "This overlay is about code. In the Book use Importance, an AI filter, Freshness or Size." : "";
    const statusText = p.error || (ui.progress ? "" : p.status) || codeOverlayInBook || "";
    el.status.textContent = statusText;
    el.status.className = p.error ? "arch-error" : statusText ? "arch-working" : "";
  }
  function localDay(date) {
    const pad = function(n) {
      return String(n).padStart(2, "0");
    };
    return date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate());
  }
  function askHistory() {
    if (el.historyDay.value) post("historyCommits", { day: el.historyDay.value });
    renderHistory();
  }
  function renderHistory() {
    const p = ui.payload || {};
    const open = ui.historyOpen && p.mode !== "folder";
    el.history.hidden = !open;
    if (!open) {
      delete el.historyList.dataset.key;
      return;
    }
    const list = el.historyList;
    const day = el.historyDay.value, h = p.history;
    const key = [day, h && h.day, h && h.state, h ? (h.commits || []).map(function(c) {
      return c.sha;
    }).join(",") : ""].join("|");
    if (list.dataset.key === key) return;
    list.dataset.key = key;
    list.textContent = "";
    const note = function(text) {
      const div = document.createElement("div");
      div.className = "arch-history-note";
      div.textContent = text;
      list.appendChild(div);
    };
    if (!day) {
      note("Choose a day.");
      return;
    }
    if (!h || h.day !== day || h.state === "loading") {
      note("Reading the history\u2026");
      return;
    }
    if (h.state === "unavailable") {
      note("The history could not be read. Is this folder a git repository?");
      return;
    }
    if (!h.commits.length) {
      note("No commits were made on this day.");
      return;
    }
    h.commits.forEach(function(c) {
      const row = document.createElement("button");
      row.type = "button";
      row.className = "arch-history-row";
      row.title = c.sha + "\n" + c.subject;
      [
        ["when", new Date(c.time * 1e3).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })],
        ["sha", c.short],
        ["what", c.subject],
        ["who", c.author]
      ].forEach(function(part) {
        const span = document.createElement("span");
        span.className = part[0];
        span.textContent = part[1];
        row.appendChild(span);
      });
      row.addEventListener("click", function() {
        ui.historyOpen = false;
        post("compareWithCommit", { sha: c.sha });
        renderHistory();
      });
      list.appendChild(row);
    });
  }
  function enter() {
    if (typeof leaveInsightView === "function") leaveInsightView();
    if (typeof window.leaveCanvasView === "function") window.leaveCanvasView();
    if (typeof window.leaveCodeView === "function") window.leaveCodeView();
    state.mode = "architecture";
    DOM.editorPane.style.display = "none";
    DOM.previewPane.style.display = "none";
    document.getElementById("wysiwyg-toolbar").style.display = "none";
    document.body.classList.add("arch-mode");
    container.classList.add("visible");
    if (DOM.statusMode) DOM.statusMode.textContent = "X-RAY";
  }
  window.architectureFocus = function(id, viewId) {
    if (viewId && viewId !== ui.view) {
      ui.view = viewId;
      ui.graphKey = null;
    }
    const view = currentView();
    if (!view) return false;
    const idx = indexView(view);
    let node = idx.byId.get(id);
    if (!node) return false;
    if (ui.view === "code" && isHidden(node, idx)) {
      ui.codeHidden.clear();
      ui.codeFilterInitialized = true;
      renderToolbar();
    }
    const expanded = ui.expanded[stateKey()];
    if ((idx.children.get(id) || []).length) expanded.add(id);
    let parent = node.parent != null ? idx.byId.get(node.parent) : null;
    while (parent) {
      expanded.add(parent.id);
      parent = parent.parent != null ? idx.byId.get(parent.parent) : null;
    }
    ui.focus[stateKey()] = (idx.children.get(id) || []).length ? id : node.parent;
    ui.selected = id;
    render(id);
    return true;
  };
  window.leaveArchitectureView = function() {
    if (!container.classList.contains("visible")) return;
    container.classList.remove("visible");
    document.body.classList.remove("arch-mode");
    document.getElementById("wysiwyg-toolbar").style.display = "";
  };
  function resetForRoot(root) {
    if (A.process) A.process.reset();
    ui.root = root;
    ui.codeFilterInitialized = false;
    ui.codeHidden.clear();
    ui.codeQuestions = {};
    ui.codeAwaitingScope = null;
    ui.selectedEdge = null;
    hideCodeSequence();
    ui.operations = null;
    Object.keys(ui.expanded).forEach(function(k) {
      ui.expanded[k].clear();
    });
    Object.keys(ui.focus).forEach(function(k) {
      ui.focus[k] = null;
    });
    ui.prExpandedFor = null;
    ui.selected = null;
    ui.graphKey = null;
    ui.ratingRequested.clear();
    ui.describeRequested.clear();
    ui.userNavigated = false;
  }
  function openChangedParts(pr) {
    if (!pr) return;
    const key = ui.prFull.id + "|" + pr.source.id + "|" + pr.files.map(function(f) {
      return f.path;
    }).join("\n");
    if (ui.prExpandedFor === key) return;
    ui.prExpandedFor = key;
    const byId = new Map(ui.prFull.nodes.map(function(n) {
      return [n.id, n];
    }));
    const prefix = ui.prFull.id === "logical" ? "l:f:" : "m:";
    pr.files.forEach(function(f) {
      for (let n = byId.get(prefix + f.path); n && n.parent != null; n = byId.get(n.parent)) ui.expanded[stateKey()].add(n.parent);
    });
  }
  window.showArchitecture = function(payload) {
    enter();
    ui.payload = payload || {};
    if ((ui.payload.root || null) !== ui.root) resetForRoot(ui.payload.root || null);
    if (ui.payload.mode === "pr") {
      if (!ui.prTab) {
        ui.prTab = true;
        ui.overlay = "pr";
        ui.selected = null;
        ui.selectedEdge = null;
      }
      ui.prView = buildPRView(ui.payload.snapshot, ui.payload.pr);
      ui.prFull = ui.prMap === "full" ? buildFullPRView(ui.payload.snapshot, ui.payload.pr) : null;
      ui.view = ui.prFull ? ui.prFull.id : "pr";
      if (ui.prFull) openChangedParts(ui.payload.pr);
      else if (ui.prView) ui.prView.nodes.forEach(function(n) {
        if (ui.prView.nodes.some(function(k) {
          return k.parent === n.id;
        })) ui.expanded.pr.add(n.id);
      });
    } else if (ui.view === "pr" || ui.prTab) {
      ui.prTab = false;
      ui.prFull = null;
      ui.selected = null;
      ui.selectedEdge = null;
      ui.view = "logical";
      ui.overlay = "none";
    }
    renderToolbar();
    el.crumbs.hidden = ui.view === "process";
    el.legend.hidden = ui.view === "process";
    if (ui.view === "process" && A.process) {
      A.process.render(ui.payload);
      return;
    }
    if (A.process) A.process.hide();
    renderDetails();
    const snap = ui.payload.snapshot;
    const traces = snap && snap.codeSequences || [];
    if (ui.view === "code" && ui.codeAwaitingScope && !ui.payload.busy && traces.map(function(s) {
      return s.createdAt;
    }).join("|") !== ui.codePreviousTime) {
      const latest = traces.length - 1;
      if (latest >= 0 && traces[latest].scope === ui.codeAwaitingScope) {
        showCodeSequence(latest);
        ui.codeAwaitingScope = null;
      }
    }
    if (!snap) {
      if (A.cy) A.cy.elements().remove();
      return;
    }
    if (!ui.viewChosen && snap.views.some(function(v) {
      return v.id === "code" && v.nodes.some(function(n) {
        return n.kind === "file";
      });
    })) {
      ui.view = "code";
      renderToolbar();
      renderDetails();
    }
    if (!ui.viewChosen && ui.view === "logical" && !snap.views.some(function(v) {
      return v.id === "logical";
    })) {
      ui.view = "modules";
      ui.graphKey = null;
      renderToolbar();
    }
    if (ui.view === "code" && !ui.codeFilterInitialized) {
      const view = currentView();
      const files = view ? view.nodes.filter(function(n) {
        return n.kind === "file";
      }) : [];
      if (files.length) {
        const defaults = ["tests"];
        const product = files.some(function(n) {
          return !(n.tags || []).some(function(t) {
            return defaults.indexOf(t) >= 0;
          });
        });
        ui.codeHidden = new Set(product ? defaults : []);
        ui.codeFilterInitialized = true;
        renderToolbar();
      }
    }
    loadLibraries().then(function() {
      if (ui.view === "process") return;
      ensureCy();
      const shape = (snap.components || []).map(function(c) {
        return c.id + "<" + c.parent;
      }).join(",") + "|" + (snap.codeModel ? JSON.stringify(snap.codeModel) : "") + "|" + Object.keys(snap.assignments || {}).length + "|" + snap.views.map(function(v) {
        return v.id + ":" + v.nodes.length;
      }).join(",");
      const pr = ui.payload.pr;
      const prShape = ui.prTab && pr ? "|" + pr.source.id + ":" + pr.files.length + ":" + (pr.dependencies || []).length + ":" + !!pr.analysis + ":" + pr.files.map(function(f) {
        return (f.changes || []).length + (f.changeSummary ? "e" : "");
      }).join(",") : "";
      const key = ui.view + "|" + snap.scannedAt + "|" + (snap.enrichedAt || "") + "|" + shape + prShape;
      if (key !== ui.graphKey) autoExpand(snap);
      if (key !== ui.graphKey) {
        ui.graphKey = key;
        render();
      } else {
        restyle();
        renderToolbar();
      }
    }).catch(function(error) {
      el.status.textContent = "Architecture view failed to load: " + error.message;
      el.status.className = "arch-error";
    });
  };
  el.views.forEach(function(b) {
    b.addEventListener("click", function() {
      hideCodeSequence();
      ui.view = b.getAttribute("data-arch-view");
      ui.viewChosen = true;
      ui.selectedEdge = null;
      ui.selected = null;
      if (ui.view === "deployment" && !isSearch(currentFilter())) ui.overlay = "none";
      ui.graphKey = null;
      window.showArchitecture(ui.payload);
    });
  });
  el.deploy.addEventListener("click", function() {
    const deploys = visibleOperations().filter(function(o) {
      return o.kind === "deploy";
    });
    if (deploys.length === 1) {
      const operation = deploys[0];
      post(isOperationRunning(operation) ? "operationOpen" : "operationRun", { id: operation.id });
    } else if (deploys.length > 1) {
      el.deployPicker.hidden = !el.deployPicker.hidden;
      if (!el.deployPicker.hidden) el.deployPicker.focus();
    }
  });
  el.deployPicker.addEventListener("change", function() {
    const operation = visibleOperations().find(function(o) {
      return o.id === el.deployPicker.value;
    });
    if (!operation) return;
    post(isOperationRunning(operation) ? "operationOpen" : "operationRun", { id: operation.id });
    el.deployPicker.value = "";
    el.deployPicker.hidden = true;
  });
  el.overlay.addEventListener("change", function() {
    if (el.overlay.value === "__new__") {
      el.overlay.value = ui.overlay;
      renderNewFilterForm();
      return;
    }
    ui.overlay = el.overlay.value;
    if (ui.overlay === "pr") post("refreshPRSources");
    renderToolbar();
    if (ui.onlyFlagged || isAIFilter()) render();
    else restyle();
  });
  el.prSource.addEventListener("change", function() {
    if (ui.payload && ui.payload.mode === "pr" && el.prSource.value.indexOf("at:") !== 0) post("openPRXRay", { source: el.prSource.value });
    else post("showPR", { source: el.prSource.value });
  });
  Array.prototype.forEach.call(el.prMap.querySelectorAll("[data-arch-pr-map]"), function(b) {
    b.addEventListener("click", function() {
      ui.prMap = b.getAttribute("data-arch-pr-map");
      ui.selected = null;
      ui.selectedEdge = null;
      ui.graphKey = null;
      window.showArchitecture(ui.payload);
    });
  });
  el.prDate.addEventListener("click", function() {
    ui.historyOpen = !ui.historyOpen;
    if (ui.historyOpen) {
      const today = localDay(/* @__PURE__ */ new Date());
      el.historyDay.max = today;
      if (!el.historyDay.value) el.historyDay.value = today;
      askHistory();
    } else renderHistory();
  });
  el.historyDay.addEventListener("change", askHistory);
  el.history.addEventListener("keydown", function(e) {
    if (e.key === "Escape") {
      ui.historyOpen = false;
      renderHistory();
    }
  });
  el.prOpen.addEventListener("click", function() {
    const current = ui.payload && ui.payload.pr ? ui.payload.pr.source.id : "";
    post("openPRXRay", { source: current });
  });
  el.analyzePR.addEventListener("click", function() {
    const pr = ui.payload && ui.payload.pr;
    post("analyzePR", { again: !!(pr && pr.analysis) });
  });
  el.prNumber.addEventListener("submit", function(e) {
    e.preventDefault();
    const text = el.prNumber.querySelector("input").value.trim();
    if (text) post("openPRNumber", { text });
    el.prNumber.querySelector("input").value = "";
  });
  el.flagged.addEventListener("change", function() {
    ui.onlyFlagged = el.flagged.checked;
    render();
  });
  el.hide.addEventListener("change", function() {
    const hidden = new Set(el.hide.value ? el.hide.value.split(",") : []);
    if (ui.view === "code") {
      ui.codeHidden = hidden;
      ui.codeFilterInitialized = true;
    } else ui.hidden = hidden;
    render();
  });
  let progressTimer = null;
  function clock(seconds) {
    seconds = Math.max(0, Math.round(seconds));
    return Math.floor(seconds / 60) + ":" + String(seconds % 60).padStart(2, "0");
  }
  function renderProgress() {
    const p = ui.progress;
    el.progress.hidden = !p;
    if (!p) {
      clearInterval(progressTimer);
      progressTimer = null;
      return;
    }
    const steps = el.progress.querySelector(".arch-progress-steps");
    steps.textContent = "";
    for (let i = 1; i <= p.steps; i++) {
      const s = document.createElement("span");
      const counted = i === p.step && p.total > 0;
      s.className = i < p.step ? "done" : i === p.step ? counted ? "counted" : "now" : "";
      if (counted) {
        const fill = document.createElement("b");
        fill.style.width = Math.min(100, 100 * p.done / p.total) + "%";
        s.appendChild(fill);
      }
      steps.appendChild(s);
    }
    el.progress.querySelector(".arch-progress-title").textContent = (p.steps > 1 ? "Step " + p.step + " of " + p.steps + ": " : "") + p.title + (p.scope ? " \xB7 " + p.scope : "") + (p.assistant ? " \u2014 " + p.assistant : "");
    const now = Date.now();
    const stats = [clock((now - Date.parse(p.stepStartedAt)) / 1e3) + (p.steps > 1 ? " (total " + clock((now - Date.parse(p.startedAt)) / 1e3) + ")" : "")];
    if (p.total > 0) stats.unshift(formatCount(p.done) + " of " + formatCount(p.total) + " " + (p.unit || ""));
    if (p.filesRead) stats.push(p.filesRead + (p.filesRead === 1 ? " file read" : " files read"));
    if (p.searches) stats.push(p.searches + (p.searches === 1 ? " search" : " searches"));
    if (p.answerChars) stats.push("result " + formatCount(p.answerChars) + " chars");
    el.progress.querySelector(".arch-progress-stats").textContent = stats.join(" \xB7 ");
    el.progress.querySelector(".arch-progress-current").textContent = p.current || "Waiting for the assistant\u2026";
    if (!progressTimer) progressTimer = setInterval(renderProgress, 1e3);
  }
  window.setArchitectureProgress = function(progress) {
    const stepChanged = !ui.progress || !progress || ui.progress.step !== progress.step;
    if (!ui.progress && progress && progress.steps > 1) ui.userNavigated = false;
    ui.progress = progress || null;
    renderProgress();
    renderToolbar();
    if (stepChanged) renderEmpty();
  };
  window.setProjectOperations = function(value) {
    ui.operations = value || null;
    renderDeployButton();
    renderDetails();
  };
  el.stop.addEventListener("click", function() {
    el.stop.disabled = true;
    post("cancelAnalysis");
    setTimeout(function() {
      el.stop.disabled = false;
    }, 1500);
  });
  const archMain = el.details.parentElement;
  window.MVPanels.resizable({
    handle: el.detailsResizer,
    panel: el.details,
    host: archMain,
    key: "markview-xray-details-width",
    width: 280,
    reserve: 320,
    onResize: function() {
      if (A.cy) A.cy.resize();
    }
  });
  function setDetailsHidden(hidden, save) {
    el.details.hidden = el.detailsResizer.hidden = hidden;
    el.detailsToggle.classList.toggle("on", !hidden);
    if (save) {
      try {
        localStorage.setItem("markview-xray-details-hidden", hidden ? "1" : "");
      } catch (e) {
      }
    }
    if (A.cy) A.cy.resize();
  }
  const compactDetails = function() {
    const scale = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--ui-scale")) || 1;
    return window.innerWidth < 1100 || scale >= 1.5;
  };
  let detailsUserChoice = false;
  let detailsHidden = compactDetails();
  try {
    const saved = localStorage.getItem("markview-xray-details-hidden");
    if (saved !== null) {
      detailsHidden = saved === "1";
      detailsUserChoice = true;
    }
  } catch (e) {
  }
  setDetailsHidden(detailsHidden, false);
  el.codeTrace.addEventListener("click", function() {
    setDetailsHidden(false, false);
    const input = el.details.querySelector(".arch-code-question");
    if (input) input.focus();
  });
  el.detailsToggle.addEventListener("click", function() {
    detailsUserChoice = true;
    setDetailsHidden(!el.details.hidden, true);
  });
  window.addEventListener("resize", function() {
    if (!detailsUserChoice) setDetailsHidden(compactDetails(), false);
  });
  function askBook(text) {
    ui.pendingTemp = text;
    ui.onlyFlagged = false;
    setDetailsHidden(false, false);
    post("askBook", { question: text });
  }
  el.tempFilter.addEventListener("submit", function(e) {
    e.preventDefault();
    const text = el.tempFilter.querySelector("input").value.trim();
    if (text) {
      askBook(text);
      return;
    }
    ui.pendingTemp = null;
    post("tempFilter", { criterion: "" });
  });
  el.tempFilter.querySelector("button").addEventListener("click", function() {
    el.tempFilter.querySelector("input").value = "";
    ui.pendingTemp = null;
    post("tempFilter", { criterion: "" });
  });
  el.review.addEventListener("click", function() {
    const pr = ui.payload && ui.payload.pr;
    post("reviewPR", { again: !!(pr && pr.reviewed) });
  });
  el.analyze.addEventListener("click", function() {
    post(ui.view === "code" ? "refreshCode" : "analyze");
  });
  el.rescan.addEventListener("click", function() {
    post("rescan");
  });
  el.fit.addEventListener("click", function() {
    if (ui.view === "process" && A.process) {
      A.process.fit();
      return;
    }
    if (!A.cy) return;
    if (ui.view === "code") A.cy.fit(A.cy.elements(), 28);
    else A.cy.animate({ fit: { eles: A.cy.elements(), padding: 28 }, duration: 240 });
  });
  ["setContent", "setStructuredContent", "setCodeContent"].forEach(function(name) {
    const original = window[name];
    if (typeof original !== "function") return;
    window[name] = function() {
      window.leaveArchitectureView();
      return original.apply(this, arguments);
    };
  });
  const origSetTheme = window.setTheme;
  window.setTheme = function(id, accent, definition) {
    origSetTheme(id, accent, definition);
    if (A.cy) {
      A.cy.style(stylesheet());
      restyle();
    }
  };
})(window.MVArchitecture);
;
const dv = {
  overlay: null,
  viewport: null,
  world: null,
  zoomLabel: null,
  tx: 0,
  ty: 0,
  scale: 1,
  minScale: 0.05,
  maxScale: 10,
  naturalW: 0,
  naturalH: 0,
  pan: null,
  suppressClick: false
};
function dvApplyTransform() {
  dv.world.style.transform = "translate(" + dv.tx + "px," + dv.ty + "px) scale(" + dv.scale + ")";
  if (dv.zoomLabel) dv.zoomLabel.textContent = Math.round(dv.scale * 100) + "%";
}
function dvZoomFit() {
  const vp = dv.viewport.getBoundingClientRect();
  if (!dv.naturalW || !dv.naturalH || vp.width < 40 || vp.height < 40) return;
  let s = Math.min(vp.width / dv.naturalW, vp.height / dv.naturalH) * 0.92;
  s = Math.min(s, 3);
  dv.scale = Math.max(dv.minScale, Math.min(dv.maxScale, s));
  dv.tx = (vp.width - dv.naturalW * dv.scale) / 2;
  dv.ty = (vp.height - dv.naturalH * dv.scale) / 2;
  dvApplyTransform();
}
function dvSetZoom(s, pivot) {
  const vp = dv.viewport.getBoundingClientRect();
  const p = pivot || { x: vp.width / 2, y: vp.height / 2 };
  s = Math.max(dv.minScale, Math.min(dv.maxScale, s));
  const wx = (p.x - dv.tx) / dv.scale, wy = (p.y - dv.ty) / dv.scale;
  dv.scale = s;
  dv.tx = p.x - wx * s;
  dv.ty = p.y - wy * s;
  dvApplyTransform();
}
function dvZoomBy(factor, pivot) {
  dvSetZoom(dv.scale * factor, pivot);
}
function dvZoomActual() {
  const vp = dv.viewport.getBoundingClientRect();
  dv.scale = 1;
  dv.tx = (vp.width - dv.naturalW) / 2;
  dv.ty = (vp.height - dv.naturalH) / 2;
  dvApplyTransform();
}
function closeDiagramViewer() {
  if (!dv.overlay) return;
  dv.overlay.classList.remove("visible");
  dv.world.innerHTML = "";
  dv.pan = null;
}
function dvPanMove(ev) {
  if (!dv.pan) return;
  const dx = ev.clientX - dv.pan.x, dy = ev.clientY - dv.pan.y;
  if (Math.abs(dx) > 3 || Math.abs(dy) > 3) dv.pan.moved = true;
  dv.tx = dv.pan.tx + dx;
  dv.ty = dv.pan.ty + dy;
  dvApplyTransform();
}
function dvPanEnd() {
  if (!dv.pan) return;
  dv.suppressClick = dv.pan.moved === true;
  dv.pan = null;
  dv.viewport.classList.remove("panning");
}
function dvEnsureOverlay() {
  if (dv.overlay) return;
  const overlay = document.createElement("div");
  overlay.className = "diagram-viewer";
  overlay.innerHTML = '<div class="diagram-viewer-toolbar"><button type="button" data-action="fit" title="Fit to window (0)">Fit</button><button type="button" data-action="actual" title="Actual size (1)">100%</button><button type="button" data-action="out" title="Zoom out (\u2212)">\u2212</button><span class="diagram-viewer-zoom-label">100%</span><button type="button" data-action="in" title="Zoom in (+)">+</button><button type="button" data-action="close" title="Close (Esc)">\u2715</button></div><div class="diagram-viewer-viewport"><div class="diagram-viewer-world"></div></div>';
  document.body.appendChild(overlay);
  dv.overlay = overlay;
  dv.viewport = overlay.querySelector(".diagram-viewer-viewport");
  dv.world = overlay.querySelector(".diagram-viewer-world");
  dv.zoomLabel = overlay.querySelector(".diagram-viewer-zoom-label");
  overlay.querySelector(".diagram-viewer-toolbar").addEventListener("click", (ev) => {
    const btn = ev.target.closest("button[data-action]");
    if (!btn) return;
    const action = btn.getAttribute("data-action");
    if (action === "fit") dvZoomFit();
    else if (action === "actual") dvZoomActual();
    else if (action === "in") dvZoomBy(1.25);
    else if (action === "out") dvZoomBy(0.8);
    else if (action === "close") closeDiagramViewer();
  });
  dv.viewport.addEventListener("wheel", (ev) => {
    ev.preventDefault();
    const rect = dv.viewport.getBoundingClientRect();
    const pivot = { x: ev.clientX - rect.left, y: ev.clientY - rect.top };
    if (ev.shiftKey && !ev.ctrlKey && !ev.metaKey) {
      dv.tx -= ev.deltaX;
      dv.ty -= ev.deltaY;
      dvApplyTransform();
    } else {
      dvZoomBy(Math.exp(-ev.deltaY * 0.01), pivot);
    }
  }, { passive: false });
  dv.viewport.addEventListener("mousedown", (ev) => {
    if (ev.button !== 0 && ev.button !== 1) return;
    dv.pan = { x: ev.clientX, y: ev.clientY, tx: dv.tx, ty: dv.ty, moved: false };
    dv.viewport.classList.add("panning");
    ev.preventDefault();
  });
  window.addEventListener("mousemove", dvPanMove);
  window.addEventListener("mouseup", dvPanEnd);
  dv.viewport.addEventListener("click", (ev) => {
    if (dv.suppressClick) {
      dv.suppressClick = false;
      return;
    }
    if (ev.target !== dv.viewport && ev.target !== dv.world) return;
    closeDiagramViewer();
  });
  dv.viewport.addEventListener("dblclick", (ev) => {
    if (ev.target === dv.viewport || ev.target === dv.world) return;
    dvZoomFit();
  });
  document.addEventListener("keydown", (ev) => {
    if (!dv.overlay || !dv.overlay.classList.contains("visible")) return;
    if (ev.key === "Escape") {
      closeDiagramViewer();
      ev.preventDefault();
    } else if (ev.key === "+" || ev.key === "=") {
      dvZoomBy(1.25);
      ev.preventDefault();
    } else if (ev.key === "-") {
      dvZoomBy(0.8);
      ev.preventDefault();
    } else if (ev.key === "0") {
      dvZoomFit();
      ev.preventDefault();
    } else if (ev.key === "1") {
      dvZoomActual();
      ev.preventDefault();
    }
  });
}
function openDiagramViewer(svgEl) {
  if (!svgEl) return;
  dvEnsureOverlay();
  const clone = svgEl.cloneNode(true);
  let w = 0, h = 0;
  const vb = svgEl.viewBox && svgEl.viewBox.baseVal;
  if (vb && vb.width > 0 && vb.height > 0) {
    w = vb.width;
    h = vb.height;
  } else {
    const r = svgEl.getBoundingClientRect();
    w = r.width || 800;
    h = r.height || 600;
  }
  clone.setAttribute("width", w);
  clone.setAttribute("height", h);
  clone.style.maxWidth = "none";
  clone.style.width = w + "px";
  clone.style.height = h + "px";
  dv.naturalW = w;
  dv.naturalH = h;
  dv.world.innerHTML = "";
  dv.world.appendChild(clone);
  dv.overlay.classList.add("visible");
  dvZoomFit();
}
function decorateMermaidDiagrams() {
  document.querySelectorAll(".mermaid").forEach((div) => {
    if (div.querySelector(".mermaid-expand-btn")) return;
    const svg = div.querySelector("svg");
    if (!svg) return;
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "mermaid-expand-btn";
    btn.title = "Open full screen (or double-click the diagram)";
    btn.textContent = "\u26F6";
    btn.addEventListener("click", (ev) => {
      ev.stopPropagation();
      openDiagramViewer(div.querySelector("svg"));
    });
    div.appendChild(btn);
  });
}
document.addEventListener("dblclick", (ev) => {
  if (dv.overlay && dv.overlay.contains(ev.target)) return;
  const diagram = ev.target.closest && ev.target.closest(".mermaid");
  if (!diagram) return;
  const svg = diagram.querySelector("svg");
  if (!svg) return;
  ev.preventDefault();
  openDiagramViewer(svg);
});
;
function initMermaidCanvas(container, mermaidSource) {
  if (typeof d3 === "undefined") {
    container.innerHTML = '<div style="padding:20px;color:#808080;">Loading libraries...</div>';
    return;
  }
  if (typeof ELK === "undefined") {
    const tag = document.createElement("script");
    tag.src = "vendor/js/elk.bundled.js";
    tag.onload = () => initMermaidCanvas(container, mermaidSource);
    tag.onerror = () => {
      container.innerHTML = '<div style="padding:20px;color:#808080;">Layout engine failed to load</div>';
    };
    document.head.appendChild(tag);
    return;
  }
  const isDark = document.documentElement.getAttribute("data-theme") !== "light";
  const bg = MarkViewThemes.token("--bg-primary");
  const textColor = MarkViewThemes.token("--text-primary");
  const linkColor = isDark ? "#555" : "#bbb";
  const tc = {
    service: "#4ec9b0",
    database: "#c586c0",
    api: "#569cd6",
    queue: "#ce9178",
    system: "#9cdcfe",
    gateway: "#dcdcaa",
    cache: "#d7ba7d",
    pipeline: "#dcdcaa",
    worker: "#ce9178",
    scheduler: "#c586c0",
    process: "#4ec9b0",
    strategy: "#569cd6",
    risk: "#f44747",
    instrument: "#c586c0",
    ui: "#9cdcfe",
    library: "#808080",
    external: "#f44747",
    data: "#c586c0",
    decision: "#d7ba7d",
    actor: "#9cdcfe",
    config: "#808080",
    default: "#808080"
  };
  const groupColors = ["#264f78", "#2d4a22", "#4a2d22", "#2d2d4a", "#4a4a22", "#224a4a"];
  function guessType(label) {
    const l = label.toLowerCase();
    if (l.includes("db") || l.includes("database") || l.includes("postgres") || l.includes("redis") || l.includes("mongo") || l.includes("sql")) return "database";
    if (l.includes("api") || l.includes("endpoint") || l.includes("rest") || l.includes("grpc")) return "api";
    if (l.includes("queue") || l.includes("kafka") || l.includes("rabbit") || l.includes("nats")) return "queue";
    if (l.includes("gateway") || l.includes("nginx") || l.includes("proxy") || l.includes("cdn")) return "gateway";
    if (l.includes("pipeline") || l.includes("flow") || l.includes("stage")) return "pipeline";
    if (l.includes("service") || l.includes("svc") || l.includes("worker")) return "service";
    return "default";
  }
  const { nodes, links, groups, direction } = parseMermaid(mermaidSource);
  if (nodes.length === 0) {
    container.innerHTML = '<div style="padding:20px;color:#808080;font-size:calc(11px * var(--ui-scale, 1));">No nodes found</div>';
    return;
  }
  nodes.forEach((n) => {
    n.type = n.kind || guessType(n.label);
    n.color = tc[n.type] || tc.default;
  });
  const uniqueGroups = [...new Set(nodes.map((n) => n.group).filter(Boolean))];
  const groupColorMap = {};
  uniqueGroups.forEach((g, i) => {
    groupColorMap[g] = groupColors[i % groupColors.length];
  });
  const nodeById0 = {};
  nodes.forEach((n) => {
    nodeById0[n.id] = n;
  });
  const groupBoxes = {};
  nodes.forEach((n) => {
    const lines = n.label.replace(/<br\s*\/?>/gi, "\n").split("\n");
    const maxLineLen = Math.max(...lines.map((l) => l.trim().length));
    n.w = Math.max(maxLineLen * 7.5 + 24, 80);
    n.h = 24 + lines.length * 14;
  });
  const labelRoom = Math.max(70, Math.max(0, ...links.map((l) => (l.label || "").length)) * 6.2 + 50);
  const elkGraph = {
    id: "root",
    layoutOptions: {
      "elk.algorithm": "layered",
      "elk.direction": direction === "TB" ? "DOWN" : "RIGHT",
      "elk.hierarchyHandling": "INCLUDE_CHILDREN",
      "elk.layered.spacing.nodeNodeBetweenLayers": String(labelRoom),
      "elk.spacing.nodeNode": "34",
      "elk.spacing.edgeNode": "24",
      "elk.layered.considerModelOrder.strategy": "NODES_AND_EDGES",
      "elk.padding": "[top=30,left=30,bottom=30,right=30]"
    },
    children: [],
    edges: links.map((l, i) => ({ id: "e" + i, sources: [l.source], targets: [l.target] }))
  };
  const elkNode = (n) => ({ id: n.id, width: n.w, height: n.h });
  uniqueGroups.forEach((gName) => {
    elkGraph.children.push({
      id: "group_" + gName,
      layoutOptions: {
        "elk.padding": "[top=34,left=18,bottom=18,right=18]",
        "elk.layered.spacing.nodeNodeBetweenLayers": String(labelRoom),
        "elk.spacing.nodeNode": "34"
      },
      children: nodes.filter((n) => n.group === gName).map(elkNode)
    });
  });
  nodes.filter((n) => !n.group).forEach((n) => elkGraph.children.push(elkNode(n)));
  const layoutDone = new ELK().layout(elkGraph).then((laid) => {
    const place = (items, ox, oy) => (items || []).forEach((item) => {
      if (item.id.startsWith("group_")) {
        const gName = item.id.slice(6);
        groupBoxes[gName] = { x: ox + item.x, y: oy + item.y, w: item.width, h: item.height };
        place(item.children, ox + item.x, oy + item.y);
      } else {
        const n = nodeById0[item.id];
        if (n) {
          n.x = ox + item.x + item.width / 2;
          n.y = oy + item.y + item.height / 2;
        }
      }
    });
    place(laid.children, 0, 0);
  });
  const draw = function() {
    const w = container.clientWidth || 800;
    const h = container.clientHeight || 600;
    container.innerHTML = "";
    const popup = document.createElement("div");
    popup.className = "canvas-popup";
    popup.id = "popup-" + container.id;
    container.appendChild(popup);
    const svg = d3.select(container).append("svg").attr("width", "100%").attr("height", "100%").style("background", bg);
    const g = svg.append("g");
    svg.append("defs").append("marker").attr("id", "arr-" + container.id).attr("viewBox", "0 -5 10 10").attr("refX", 9).attr("refY", 0).attr("markerWidth", 6).attr("markerHeight", 6).attr("orient", "auto").append("path").attr("d", "M0,-5L10,0L0,5").attr("fill", linkColor);
    uniqueGroups.forEach((gName) => {
      const box = groupBoxes[gName];
      if (!box) return;
      g.append("rect").attr("x", box.x).attr("y", box.y).attr("width", box.w).attr("height", box.h).attr("rx", 8).attr("ry", 8).attr("fill", groupColorMap[gName] || "#333").attr("fill-opacity", 0.12).attr("stroke", groupColorMap[gName] || "#555").attr("stroke-opacity", 0.3);
      g.append("text").attr("x", box.x + 10).attr("y", box.y + 20).attr("font-size", 11).attr("fill", "#9a9a9a").attr("font-weight", "bold").text(gName);
    });
    const nodeById = {};
    nodes.forEach((n) => {
      nodeById[n.id] = n;
    });
    links.forEach((l) => {
      if (typeof l.source === "string") l.srcNode = nodeById[l.source];
      else l.srcNode = l.source;
      if (typeof l.target === "string") l.tgtNode = nodeById[l.target];
      else l.tgtNode = l.target;
    });
    function endpoints(l) {
      const a = l.srcNode, b = l.tgtNode;
      const dx = b.x - a.x, dy = b.y - a.y;
      function clip(n, ux2, uy2) {
        const hw = (n.w || 70) / 2, hh = (n.h || 32) / 2;
        const t = Math.min(ux2 ? hw / Math.abs(ux2) : Infinity, uy2 ? hh / Math.abs(uy2) : Infinity);
        return [n.x + ux2 * t, n.y + uy2 * t];
      }
      const len = Math.hypot(dx, dy) || 1;
      const ux = dx / len, uy = dy / len;
      const p1 = clip(a, ux, uy), p2 = clip(b, -ux, -uy);
      return { x1: p1[0], y1: p1[1], x2: p2[0], y2: p2[1] };
    }
    const edgeGroup = g.append("g");
    const edgeElements = [];
    links.forEach((l, i) => {
      if (!l.srcNode || !l.tgtNode) return;
      const ep = endpoints(l);
      const line = edgeGroup.append("line").attr("x1", ep.x1).attr("y1", ep.y1).attr("x2", ep.x2).attr("y2", ep.y2).attr("stroke", linkColor).attr("stroke-width", 1.5).attr("marker-end", "url(#arr-" + container.id + ")").style("cursor", "pointer").attr("data-idx", i);
      const labelEl = l.label ? edgeGroup.append("text").attr("x", (ep.x1 + ep.x2) / 2).attr("y", (ep.y1 + ep.y2) / 2 - 4).attr("font-size", 10).attr("fill", isDark ? "#c0c0c0" : "#444").attr("text-anchor", "middle").attr("paint-order", "stroke").attr("stroke", bg).attr("stroke-width", 4).attr("stroke-linejoin", "round").text(l.label).style("pointer-events", "none").attr("data-idx", i) : null;
      edgeElements.push({ line, labelEl, link: l });
      line.on("click", (event) => {
        event.stopPropagation();
        showPopup(
          popup,
          event.pageX - container.getBoundingClientRect().left,
          event.pageY - container.getBoundingClientRect().top,
          `<div class="popup-title">${window.mvKit.escapeHtml(l.srcNode.label)} \u2192 ${window.mvKit.escapeHtml(l.tgtNode.label)}</div>
                         <div class="popup-type">${window.mvKit.escapeHtml(l.label || "depends on")}</div>
                         ${l.evidence ? `<div class="popup-actions"><button class="popup-btn" data-open-source="${window.mvKit.escapeHtml(l.evidence)}">Evidence: ${window.mvKit.escapeHtml(l.evidence)}</button></div>` : ""}
                         <div class="popup-actions">
                           <input class="popup-input" id="edge-prompt-${container.id}" placeholder="Ask AI to change..." />
                           <button class="popup-btn" data-ai-edit="${window.mvKit.escapeHtml(container.id)}" data-ai-input="edge-prompt-${window.mvKit.escapeHtml(container.id)}" data-ai-prefix="${window.mvKit.escapeHtml("Change relationship between " + l.srcNode.label + " and " + l.tgtNode.label + ": ")}">AI Edit</button>
                         </div>`
        );
      });
    });
    function updateEdges() {
      edgeElements.forEach(({ line, labelEl, link }) => {
        if (!link.srcNode || !link.tgtNode) return;
        const ep = endpoints(link);
        line.attr("x1", ep.x1).attr("y1", ep.y1).attr("x2", ep.x2).attr("y2", ep.y2);
        if (labelEl) labelEl.attr("x", (ep.x1 + ep.x2) / 2).attr("y", (ep.y1 + ep.y2) / 2 - 4);
      });
    }
    const nodeGroup = g.append("g");
    nodes.forEach((n) => {
      const ng = nodeGroup.append("g").attr("transform", `translate(${n.x},${n.y})`).attr("data-id", n.id).attr("data-group", n.group || "").style("cursor", "grab").call(
        d3.drag().on("drag", function(event) {
          n.x = event.x;
          n.y = event.y;
          d3.select(this).attr("transform", `translate(${n.x},${n.y})`);
          updateEdges();
        })
      );
      ng.append("rect").attr("rx", 6).attr("ry", 6).attr("width", n.w || 70).attr("height", n.h || 32).attr("x", -(n.w || 70) / 2).attr("y", -(n.h || 32) / 2).attr("fill", n.color).attr("fill-opacity", 0.15).attr("stroke", n.color).attr("stroke-width", 1.5);
      const labelLines = n.label.replace(/<br\s*\/?>/gi, "\n").split("\n");
      const textEl = ng.append("text").attr("text-anchor", "middle").attr("font-size", 11).attr("fill", textColor).style("pointer-events", "none");
      labelLines.forEach((line, li) => {
        textEl.append("tspan").attr("x", 0).attr("dy", li === 0 ? -(labelLines.length - 1) * 6 + 4 : 13).text(line.trim());
      });
      ng.on("click", (event) => {
        event.stopPropagation();
        const rect = container.getBoundingClientRect();
        showPopup(
          popup,
          event.pageX - rect.left,
          event.pageY - rect.top,
          `<div class="popup-title">${window.mvKit.escapeHtml(n.label)}</div>
                         <div class="popup-type">[${window.mvKit.escapeHtml(n.type)}] ${n.group ? "\u2022 " + window.mvKit.escapeHtml(n.group) : ""}</div>
                         ${n.note ? `<div class="popup-type">${window.mvKit.escapeHtml(n.note)}</div>` : ""}
                         ${n.source ? `<div class="popup-actions"><button class="popup-btn" data-open-source="${window.mvKit.escapeHtml(n.source)}">Open ${window.mvKit.escapeHtml(n.source)}</button></div>` : ""}
                         <div class="popup-actions">
                           <input class="popup-input" id="node-prompt-${container.id}" placeholder="Ask AI: remove, replace, modify..." />
                           <button class="popup-btn" data-ai-edit="${window.mvKit.escapeHtml(container.id)}" data-ai-input="node-prompt-${window.mvKit.escapeHtml(container.id)}" data-ai-prefix="${window.mvKit.escapeHtml("Regarding " + n.label + ": ")}">AI Edit</button>
                           <button class="popup-btn danger" data-ai-edit="${window.mvKit.escapeHtml(container.id)}" data-ai-fixed="${window.mvKit.escapeHtml("Remove " + n.label + " from the diagram and adjust connections")}">Delete</button>
                         </div>`
        );
      });
    });
    svg.on("click", () => {
      popup.style.display = "none";
    });
    const zoom = d3.zoom().scaleExtent([0.1, 5]).on("zoom", (e) => g.attr("transform", e.transform));
    svg.call(zoom);
    const graphBounds = g.node().getBBox();
    if (graphBounds.width > 0) {
      const scale = Math.min(w / (graphBounds.width + 60), h / (graphBounds.height + 60), 1.5);
      const tx = (w - graphBounds.width * scale) / 2 - graphBounds.x * scale;
      const ty = (h - graphBounds.height * scale) / 2 - graphBounds.y * scale;
      svg.call(zoom.transform, d3.zoomIdentity.translate(tx, ty).scale(scale));
    }
    const filterBar = document.createElement("div");
    filterBar.style.cssText = "position:absolute;top:4px;left:4px;display:flex;gap:3px;flex-wrap:wrap;max-width:80%;";
    const btnStyle = `padding:2px 6px;border:1px solid ${MarkViewThemes.token("--border-color")};background:${MarkViewThemes.token("--bg-secondary")};color:${textColor};border-radius:3px;font-size:calc(9px * var(--ui-scale, 1));cursor:pointer;`;
    const allBtn = document.createElement("button");
    allBtn.style.cssText = btnStyle;
    allBtn.textContent = "All";
    allBtn.addEventListener("click", () => filterCanvasGroup(container.id, "all"));
    filterBar.appendChild(allBtn);
    uniqueGroups.forEach((gName) => {
      const btn = document.createElement("button");
      btn.style.cssText = btnStyle;
      btn.textContent = gName;
      btn.onclick = () => filterCanvasGroup(container.id, gName);
      filterBar.appendChild(btn);
    });
    container.appendChild(filterBar);
    const ctrl = document.createElement("div");
    ctrl.style.cssText = "position:absolute;bottom:4px;right:4px;display:flex;gap:4px;align-items:center;";
    ctrl.innerHTML = `
                <span style="font-size:calc(8px * var(--ui-scale, 1));color:#808080;">${nodes.length} nodes, ${links.length} edges</span>
            `;
    container.appendChild(ctrl);
    container._canvasData = { nodes, links, edgeElements, nodeGroup, edgeGroup, uniqueGroups };
  };
  layoutDone.then(draw).catch((err) => {
    container.innerHTML = '<div style="padding:20px;color:#f44747;font-size:11px;">Layout failed: ' + window.mvKit.escapeHtml(err && err.message || err) + "</div>";
  });
}
function openDiagramSource(ref) {
  const path = String(ref).split(":")[0];
  if (path) sendToSwift("canvasOpenFile", { path });
}
function showPopup(popup, x, y, html) {
  popup.innerHTML = html;
  popup.querySelectorAll("[data-open-source]").forEach((btn) => {
    btn.addEventListener("click", () => openDiagramSource(btn.getAttribute("data-open-source")));
  });
  popup.querySelectorAll("[data-ai-edit]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const cid = btn.getAttribute("data-ai-edit");
      const fixed = btn.getAttribute("data-ai-fixed");
      if (fixed) {
        aiEditGraph(cid, fixed);
      } else {
        const inputEl = document.getElementById(btn.getAttribute("data-ai-input"));
        const prefix = btn.getAttribute("data-ai-prefix") || "";
        aiEditGraph(cid, prefix + (inputEl ? inputEl.value : ""));
      }
    });
  });
  popup.style.display = "block";
  popup.style.left = Math.min(x, popup.parentElement.clientWidth - 200) + "px";
  popup.style.top = Math.min(y, popup.parentElement.clientHeight - 150) + "px";
}
function filterCanvasGroup(containerId, groupName) {
  const container = document.getElementById(containerId);
  if (!container || !container._canvasData) return;
  const { nodes, edgeElements, nodeGroup, edgeGroup } = container._canvasData;
  nodeGroup.selectAll("g").each(function() {
    const el = d3.select(this);
    const group = el.attr("data-group");
    const show = groupName === "all" || group === groupName;
    el.style("opacity", show ? 1 : 0.08);
    el.style("pointer-events", show ? "all" : "none");
  });
  edgeElements.forEach(({ line, labelEl, link }) => {
    const srcGroup = link.srcNode?.group || "";
    const tgtGroup = link.tgtNode?.group || "";
    const show = groupName === "all" || srcGroup === groupName || tgtGroup === groupName;
    line.style("opacity", show ? 1 : 0.05);
    if (labelEl) labelEl.style("opacity", show ? 1 : 0.05);
  });
}
function aiEditGraph(containerId, instruction) {
  const container = document.getElementById(containerId);
  if (!container) return;
  const source = container.getAttribute("data-source");
  container.querySelector(".canvas-popup").style.display = "none";
  sendToSwift("generateGraph", {
    type: "edit",
    editInstruction: instruction,
    currentMermaid: source
  });
}
function parseMermaid(code) {
  const nodes = [], links = [], groups = [];
  const nodeMap = {};
  const lines = code.split("\n");
  let currentGroup = null;
  let direction = "LR";
  const meta = { src: {}, note: {}, evidence: [] };
  function declare(id, label, kind) {
    if (label) label = label.replace(/^"(.*)"$/, "$1");
    let n = nodeMap[id];
    if (!n) {
      n = nodeMap[id] = { id, label: label || id, group: currentGroup };
      nodes.push(n);
    } else {
      if (label) n.label = label;
      if (currentGroup && !n.group) n.group = currentGroup;
    }
    if (kind) n.kind = kind;
    return n;
  }
  for (const line of lines) {
    const trimmed = line.trim();
    let m = trimmed.match(/^%%\s+src\s+(\w+)\s+(\S+)/);
    if (m) {
      meta.src[m[1]] = m[2];
      continue;
    }
    m = trimmed.match(/^%%\s+note\s+(\w+)\s+(.+)/);
    if (m) {
      meta.note[m[1]] = m[2];
      continue;
    }
    m = trimmed.match(/^%%\s+evidence\s+(\w+)\s+(\w+)\s+(\S+)/);
    if (m) {
      meta.evidence.push({ from: m[1], to: m[2], ref: m[3] });
      continue;
    }
    if (!trimmed || trimmed.startsWith("%%") || trimmed.startsWith("classDef") || trimmed.startsWith("class ") || trimmed.startsWith("pie")) continue;
    const sgMatch = trimmed.match(/^subgraph\s+(?:\w+\s*\[\s*"([^"]+)"\s*\]|"([^"]+)"|(\S+))/);
    if (sgMatch) {
      currentGroup = sgMatch[1] || sgMatch[2] || sgMatch[3];
      groups.push(currentGroup);
      continue;
    }
    if (trimmed === "end") {
      currentGroup = null;
      continue;
    }
    const dirMatch = trimmed.match(/^(?:graph|flowchart)\s+(TB|TD|BT|LR|RL)/);
    if (dirMatch) {
      direction = dirMatch[1] === "LR" || dirMatch[1] === "RL" ? "LR" : "TB";
      continue;
    }
    if (trimmed.startsWith("graph") || trimmed.startsWith("flowchart") || trimmed.startsWith("erDiagram") || trimmed.startsWith("sequenceDiagram")) continue;
    const edgeMatch = trimmed.match(/^(\w+)(?:\[("[^"]*"|[^\]]*)\])?(?::::(\w+))?\s*(-+->|-->|==>|-.->|--)\s*(?:\|([^|]*)\|)?\s*(\w+)(?:\[("[^"]*"|[^\]]*)\])?(?::::(\w+))?/);
    if (edgeMatch) {
      const [_, srcId, srcLabel, srcKind, arrow, edgeLabel, tgtId, tgtLabel, tgtKind] = edgeMatch;
      declare(srcId, srcLabel, srcKind);
      declare(tgtId, tgtLabel, tgtKind);
      links.push({ source: srcId, target: tgtId, label: (edgeLabel || "").replace(/^"(.*)"$/, "$1").trim() });
      continue;
    }
    const nodeMatch = trimmed.match(/^(\w+)[\[({]+("[^"]*"|[^\]})]+)[\]})]+(?::::(\w+))?/);
    if (nodeMatch) {
      declare(nodeMatch[1], nodeMatch[2], nodeMatch[3]);
      continue;
    }
    const erMatch = trimmed.match(/^(\w+)\s+(\|[|o{}<>-]+)\s+(\w+)\s*:\s*(.+)/);
    if (erMatch) {
      const [_, src, rel, tgt, label] = erMatch;
      declare(src);
      declare(tgt);
      links.push({ source: src, target: tgt, label: label.trim() });
      continue;
    }
    const c4Match = trimmed.match(/^(?:Component|Container|System|Person|ComponentDb|ContainerDb|SystemDb|System_Ext|Container_Ext|Component_Ext)\((\w+),\s*"([^"]+)"(?:,\s*"([^"]*)")?(?:,\s*"([^"]*)")?\)/);
    if (c4Match) {
      const [_, id, label, tech, desc] = c4Match;
      if (!nodeMap[id]) {
        nodeMap[id] = { id, label: label + (tech ? " [" + tech + "]" : ""), group: currentGroup, description: desc || "" };
        nodes.push(nodeMap[id]);
      }
      continue;
    }
    const boundaryMatch = trimmed.match(/^(?:Container_Boundary|Boundary|Enterprise_Boundary|System_Boundary)\((\w+),\s*"([^"]+)"\)/);
    if (boundaryMatch) {
      currentGroup = boundaryMatch[2];
      groups.push(currentGroup);
      continue;
    }
    const relMatch = trimmed.match(/^(?:Rel|BiRel|Rel_D|Rel_U|Rel_L|Rel_R|Rel_Back)\((\w+),\s*(\w+),\s*"([^"]+)"(?:,\s*"([^"]*)")?\)/);
    if (relMatch) {
      const [_, src, tgt, label] = relMatch;
      if (nodeMap[src] && nodeMap[tgt]) {
        links.push({ source: src, target: tgt, label });
      }
      continue;
    }
  }
  nodes.forEach((n) => {
    if (meta.src[n.id]) n.source = meta.src[n.id];
    if (meta.note[n.id]) n.note = meta.note[n.id];
  });
  meta.evidence.forEach((e) => {
    const l = links.find((x) => x.source === e.from && x.target === e.to && !x.evidence);
    if (l) l.evidence = e.ref;
  });
  return { nodes, links, groups, direction };
}
try {
  sendToSwift("jsError", {
    where: "end-checkpoint",
    message: "reached end of <script> block \u2014 typeof loadInsightSkeleton=" + typeof window.loadInsightSkeleton + " updateInsightSection=" + typeof window.updateInsightSection + " setInsightStatus=" + typeof window.setInsightStatus,
    source: "",
    lineno: 0,
    colno: 0,
    stack: ""
  });
} catch (_) {
}
;
(function() {
  "use strict";
  const container = document.getElementById("data-container");
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
    .dv-btn.on { background: var(--accent-fill); color: var(--on-accent); border-color: var(--accent-fill); }
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
  const style = document.createElement("style");
  style.textContent = css;
  document.head.appendChild(style);
  const esc = window.mvKit.escapeHtml;
  const q = (name) => '"' + String(name).replace(/"/g, '""') + '"';
  const fmtCount = (n) => Number(n).toLocaleString();
  let current = null;
  let bundle = null;
  function loadBundle() {
    if (window.MVData) return Promise.resolve(window.MVData);
    if (bundle) return bundle;
    bundle = new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = "vendor/js/data.bundle.js";
      script.onload = () => resolve(window.MVData);
      script.onerror = () => reject(new Error("The data libraries could not be loaded."));
      document.head.appendChild(script);
    });
    return bundle;
  }
  function enterDataView() {
    if (window.leaveCodeView) window.leaveCodeView();
    if (window.leaveArchitectureView) window.leaveArchitectureView();
    if (window.leaveCanvasView) window.leaveCanvasView();
    if (typeof leaveInsightView === "function") leaveInsightView();
    if (typeof DOM !== "undefined") {
      DOM.editorPane.style.display = "none";
      DOM.previewPane.style.display = "none";
    }
    const toolbar = document.getElementById("wysiwyg-toolbar");
    if (toolbar) toolbar.style.display = "none";
    document.body.classList.add("data-mode");
    container.classList.add("visible");
  }
  window.leaveDataView = function() {
    if (!container.classList.contains("visible")) return;
    container.classList.remove("visible");
    document.body.classList.remove("data-mode");
    const toolbar = document.getElementById("wysiwyg-toolbar");
    if (toolbar) toolbar.style.display = "";
    if (current && current.viewer && current.viewer.destroy) current.viewer.destroy();
    current = null;
    container.innerHTML = "";
  };
  async function fetchBytes(src) {
    const response = await fetch(src, { cache: "no-store" });
    if (!response.ok) throw new Error("Could not read the file (" + response.status + ").");
    return new Uint8Array(await response.arrayBuffer());
  }
  function decodeText(bytes) {
    try {
      return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    } catch (e) {
      return new TextDecoder("windows-1252").decode(bytes);
    }
  }
  function message(text, isError) {
    container.innerHTML = '<div class="dv-msg' + (isError ? " error" : "") + '">' + esc(text) + "</div>";
  }
  window.setDataContent = async function(info) {
    enterDataView();
    const sameFile = current && current.src === info.src;
    if (info.reload && sameFile && current.viewer && current.viewer.reload) {
      try {
        current.viewer.reload(await fetchBytes(info.src));
      } catch (e) {
      }
      return;
    }
    if (current && current.viewer && current.viewer.destroy) current.viewer.destroy();
    current = { kind: info.kind, name: info.name, src: info.src, viewer: null };
    const mine = current;
    message("Loading " + info.name + "\u2026");
    if (typeof DOM !== "undefined" && DOM.statusMode) DOM.statusMode.textContent = info.kind.toUpperCase();
    try {
      const bytes = await fetchBytes(info.src);
      if (current !== mine) return;
      if (info.kind === "log") {
        mine.viewer = LogViewer(container, info.name, bytes);
      } else {
        const lib = await loadBundle();
        if (current !== mine) return;
        mine.viewer = await TableViewer(container, info, bytes, lib);
      }
      if (current === mine && /\.(csv|tsv|tab|psv|jsonl|ndjson|har|log|out)$/i.test(info.name)) {
        const bar = container.querySelector(".dv-bar");
        if (bar) {
          const button = document.createElement("button");
          button.className = "dv-btn dv-explain";
          button.textContent = "\u2726 Explain";
          button.title = "Explain this file section by section (AI)";
          button.addEventListener("click", function() {
            window.explainCurrentFile();
          });
          bar.appendChild(button);
        }
      }
    } catch (error) {
      if (current === mine) message(String(error && error.message || error), true);
    }
  };
  function parseText(kind, name, text, lib) {
    const ext = (name.split(".").pop() || "").toLowerCase();
    if (ext === "har") {
      const har = JSON.parse(text);
      const entries = har.log && har.log.entries || [];
      const rows = entries.map((e) => ({
        started: e.startedDateTime,
        method: e.request && e.request.method,
        url: e.request && e.request.url,
        status: e.response && e.response.status,
        status_text: e.response && e.response.statusText,
        mime: e.response && e.response.content && e.response.content.mimeType,
        size: e.response && (e.response.content && e.response.content.size >= 0 ? e.response.content.size : e.response.bodySize),
        time_ms: e.time !== void 0 ? Math.round(e.time * 10) / 10 : null,
        wait_ms: e.timings && e.timings.wait,
        server_ip: e.serverIPAddress || null,
        request_headers: e.request && JSON.stringify(e.request.headers),
        response_headers: e.response && JSON.stringify(e.response.headers)
      }));
      return { rows, errors: [], note: har.log && har.log.creator ? har.log.creator.name + " " + (har.log.creator.version || "") : "" };
    }
    if (ext === "jsonl" || ext === "ndjson") {
      const rows = [];
      const errors2 = [];
      text.split(/\r?\n/).forEach((line, index) => {
        if (!line.trim()) return;
        try {
          rows.push(flatten(JSON.parse(line)));
        } catch (e) {
          if (errors2.length < 5) errors2.push("Line " + (index + 1) + ": " + e.message);
        }
      });
      return { rows, errors: errors2, note: "" };
    }
    const delimiter = ext === "tsv" || ext === "tab" ? "	" : ext === "psv" ? "|" : "";
    const parsed = lib.Papa.parse(text, { header: true, skipEmptyLines: "greedy", delimiter, dynamicTyping: false });
    const errors = parsed.errors.slice(0, 5).map((e) => (e.row !== void 0 ? "Row " + (e.row + 2) + ": " : "") + e.message);
    return { rows: parsed.data, errors, note: parsed.meta.delimiter && !delimiter ? "delimiter " + JSON.stringify(parsed.meta.delimiter) : "" };
  }
  function flatten(value, prefix = "", out = {}, depth = 0) {
    if (value === null || typeof value !== "object" || Array.isArray(value) || depth >= 3) {
      out[prefix || "value"] = value;
      return out;
    }
    const keys = Object.keys(value);
    if (!keys.length && prefix) out[prefix] = "{}";
    for (const key of keys) flatten(value[key], prefix ? prefix + "." + key : key, out, depth + 1);
    return out;
  }
  function cellValue(value) {
    if (value === null || value === void 0) return null;
    if (typeof value === "bigint") return Number.isSafeInteger(Number(value)) ? Number(value) : value.toString();
    if (value instanceof Date) return value.toISOString();
    if (value instanceof Uint8Array) return "0x" + Array.from(value.slice(0, 32), (b) => b.toString(16).padStart(2, "0")).join("") + (value.length > 32 ? "\u2026" : "");
    if (typeof value === "object") return JSON.stringify(value, (k, v) => typeof v === "bigint" ? v.toString() : v);
    if (typeof value === "boolean") return value ? 1 : 0;
    return value;
  }
  function loadRows(db, rows, tableName) {
    const table = q(tableName || "data");
    const columns = [];
    const seen = /* @__PURE__ */ new Set();
    for (const row of rows.slice(0, 2e3)) for (const key of Object.keys(row || {})) if (!seen.has(key)) {
      seen.add(key);
      columns.push(key);
    }
    for (const row of rows) for (const key of Object.keys(row || {})) if (!seen.has(key)) {
      seen.add(key);
      columns.push(key);
    }
    if (!columns.length) columns.push("value");
    const numeric = columns.map((col) => {
      let any = false;
      for (const row of rows) {
        const v = row && row[col];
        if (v === null || v === void 0 || v === "") continue;
        if (typeof v === "number" || typeof v === "bigint") {
          any = true;
          continue;
        }
        if (typeof v === "string" && /^\s*-?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?\s*$/.test(v)) {
          any = true;
          continue;
        }
        return false;
      }
      return any;
    });
    db.run("CREATE TABLE " + table + " (" + columns.map((c, i) => q(c) + (numeric[i] ? " NUMERIC" : " TEXT")).join(", ") + ")");
    const insert = db.prepare("INSERT INTO " + table + " VALUES (" + columns.map(() => "?").join(",") + ")");
    db.run("BEGIN");
    for (const row of rows) {
      insert.run(columns.map((c, i) => {
        const v = cellValue(row ? row[c] : null);
        if (v === "" || v === null) return null;
        return numeric[i] ? Number(v) : typeof v === "number" ? String(v) : v;
      }));
    }
    db.run("COMMIT");
    insert.free();
    return columns;
  }
  async function TableViewer(root, info, bytes, lib) {
    const SQL = await lib.sql();
    const isSQLite = info.kind === "sqlite";
    const ext = (info.name.split(".").pop() || "").toLowerCase();
    let sheetNames = null;
    let db;
    let info2 = "";
    let parquetDetails = null;
    let schemaPanel = null;
    const notes = [];
    if (isSQLite) {
      db = new SQL.Database(bytes);
    } else {
      db = new SQL.Database();
      let rows;
      if (info.kind === "parquet") {
        const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
        const metadata = lib.parquet.metadata(buffer);
        const total = Number(metadata.num_rows);
        const limit = 5e5;
        rows = await lib.parquet.rows(buffer, total > limit ? { rowEnd: limit } : {});
        if (total > limit) notes.push("Showing the first " + fmtCount(limit) + " of " + fmtCount(total) + " rows.");
        parquetDetails = describeParquet(metadata, lib);
        info2 = metadata.row_groups.length + (metadata.row_groups.length === 1 ? " row group" : " row groups");
      } else if (["arrow", "feather", "ipc", "arrows"].includes(ext)) {
        const arrow = readArrow(bytes, lib);
        rows = arrow.rows;
        schemaPanel = arrow.schema;
        info2 = "Arrow IPC";
      } else if (ext === "avro") {
        const avro = readAvro(bytes, lib);
        rows = avro.rows;
        schemaPanel = avro.schema;
        info2 = "Avro \xB7 " + avro.codec;
      } else if (ext === "xlsx" || ext === "xlsm" || ext === "ods") {
        const sheets = ext === "ods" ? readOpenDocument(bytes, lib) : readWorkbook(bytes, lib);
        sheetNames = sheets.map((sheet) => sheet.name);
        sheets.forEach((sheet) => loadRows(db, sheet.rows, sheet.name));
        info2 = sheets.length + (sheets.length === 1 ? " sheet" : " sheets");
      } else {
        const parsed = parseText(info.kind, info.name, decodeText(bytes), lib);
        rows = parsed.rows;
        parsed.errors.forEach((e) => notes.push(e));
        info2 = parsed.note;
      }
      if (rows) loadRows(db, rows);
    }
    const tables = isSQLite ? db.exec("SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY type, name")[0]?.values.map((r) => r[0]) || [] : sheetNames || ["data"];
    const manyTables = isSQLite || !!sheetNames;
    let table = tables[0] || "";
    let baseSQL = table ? "SELECT * FROM " + q(table) : "";
    let sort = { column: null, desc: false };
    let filters = {};
    let search = "";
    let result = { columns: [], rows: [], total: 0, truncated: false };
    let selected = -1;
    let currentColumn = -1;
    const ROW = 25, LIMIT = 2e5;
    root.innerHTML = `
          <div class="dv-bar">
            <span class="dv-title">${esc(info.name)}</span>
            ${manyTables ? '<select class="dv-table" title="' + (sheetNames ? "Sheet" : "Table or view") + '"></select>' : ""}
            <span class="dv-meta dv-count"></span>
            <span class="dv-spacer"></span>
            <input type="search" class="dv-search" placeholder="Search all columns">
            <button class="dv-btn dv-sqlbtn" title="Query with SQL (table: ${manyTables ? "each " + (sheetNames ? "sheet" : "table") + " by name" : "data"})">SQL</button>
            <button class="dv-btn dv-stats" title="Statistics of the selected column">Column stats</button>
            ${parquetDetails || isSQLite || schemaPanel ? '<button class="dv-btn dv-schema">Schema</button>' : ""}
            <button class="dv-btn dv-export" title="Save the rows shown as CSV">Export CSV</button>
            <button class="dv-btn dv-copy" title="Copy the rows shown as TSV (paste into a spreadsheet)">Copy</button>
          </div>
          <div class="dv-sql">
            <textarea spellcheck="false"></textarea>
            <div class="dv-sql-side">
              <button class="dv-btn dv-run on" title="\u2318\u21A9">Run</button>
              <button class="dv-btn dv-reset">Reset</button>
            </div>
          </div>
          <div class="dv-msg"></div>
          <div class="dv-body"><div class="dv-grid"></div><div class="dv-side"></div></div>`;
    const $ = (s) => root.querySelector(s);
    const grid = $(".dv-grid"), side = $(".dv-side"), msg = $(".dv-msg"), sqlBox = $(".dv-sql"), sqlText = $(".dv-sql textarea");
    sqlText.value = baseSQL;
    const say = (text, isError) => {
      msg.textContent = text || "";
      msg.classList.toggle("error", !!isError);
    };
    say(notes.join("\n"), notes.length > 0 && !notes[0].startsWith("Showing"));
    if (manyTables) {
      const select = $(".dv-table");
      select.innerHTML = tables.map((t) => "<option>" + esc(t) + "</option>").join("");
      select.addEventListener("change", () => {
        table = select.value;
        baseSQL = "SELECT * FROM " + q(table);
        sqlText.value = baseSQL;
        sort = { column: null, desc: false };
        filters = {};
        search = "";
        $(".dv-search").value = "";
        run();
      });
    }
    function where(columns) {
      const parts = [];
      const params = [];
      if (search) {
        parts.push("(" + columns.map((c) => "CAST(" + q(c) + " AS TEXT) LIKE ?").join(" OR ") + ")");
        columns.forEach(() => params.push("%" + search + "%"));
      }
      for (const [column, raw] of Object.entries(filters)) {
        const text = raw.trim();
        if (!text || !columns.includes(column)) continue;
        const m = text.match(/^(>=|<=|!=|<>|=|>|<)\s*(.*)$/);
        if (/^(null|empty)$/i.test(text)) {
          parts.push("(" + q(column) + " IS NULL OR " + q(column) + " = '')");
        } else if (/^!(null|empty)$/i.test(text)) {
          parts.push("(" + q(column) + " IS NOT NULL AND " + q(column) + " != '')");
        } else if (m) {
          const op = m[1] === "<>" ? "!=" : m[1];
          const value = m[2];
          const n = Number(value);
          parts.push(q(column) + " " + op + " ?");
          params.push(value !== "" && !Number.isNaN(n) ? n : value);
        } else {
          parts.push("CAST(" + q(column) + " AS TEXT) LIKE ?");
          params.push("%" + text + "%");
        }
      }
      return { sql: parts.length ? " WHERE " + parts.join(" AND ") : "", params };
    }
    function columnsOf(sql) {
      const stmt = db.prepare("SELECT * FROM (" + sql + ") LIMIT 0");
      const names = stmt.getColumnNames();
      stmt.free();
      return names;
    }
    function run() {
      const sql = (sqlText.value || baseSQL).trim().replace(/;\s*$/, "");
      if (!sql) {
        grid.innerHTML = "";
        $(".dv-count").textContent = "No tables";
        return;
      }
      try {
        let columns;
        let finalSQL, params = [];
        if (/^\s*(select|with|values|pragma)\b/i.test(sql) && !/^\s*pragma/i.test(sql)) {
          columns = columnsOf(sql);
          const w = where(columns);
          const order = sort.column !== null && columns.includes(sort.column) ? " ORDER BY " + q(sort.column) + (sort.desc ? " DESC" : " ASC") : "";
          finalSQL = "SELECT * FROM (" + sql + ")" + w.sql + order;
          params = w.params;
          const total = db.exec("SELECT COUNT(*) FROM (" + sql + ")" + w.sql, params)[0].values[0][0];
          const stmt = db.prepare(finalSQL + " LIMIT " + LIMIT, params);
          const rows = [];
          while (stmt.step()) rows.push(stmt.get());
          stmt.free();
          result = { columns, rows, total, truncated: total > LIMIT };
        } else {
          const out = db.exec(sql);
          const last = out[out.length - 1];
          result = last ? { columns: last.columns, rows: last.values, total: last.values.length, truncated: false } : { columns: [], rows: [], total: 0, truncated: false };
          say("Done. Changes stay in this view only; the file is not modified.");
        }
        selected = -1;
        render();
        if (!msg.classList.contains("error") && /^\s*(select|with|values)\b/i.test(sql)) say(notes.join("\n"));
      } catch (error) {
        say("SQL error: " + (error.message || error), true);
      }
    }
    function render() {
      const { columns, rows, total, truncated } = result;
      $(".dv-count").textContent = fmtCount(total) + " rows" + (truncated ? " (first " + fmtCount(LIMIT) + " shown)" : "") + " \xB7 " + columns.length + " columns" + (info2 ? " \xB7 " + info2 : "");
      const head = '<tr><th class="dv-rownum">#</th>' + columns.map((c, i) => '<th data-col="' + i + '" title="' + esc(c) + ' \u2014 click to sort">' + esc(c) + (sort.column === c ? sort.desc ? " \u25BC" : " \u25B2" : "") + "</th>").join("") + '</tr><tr class="dv-filters"><th class="dv-rownum"></th>' + columns.map((c, i) => '<th><input data-col="' + i + '" placeholder="filter" title="text, =x, >10, <=5, !=x, null, !null" value="' + esc(filters[c] || "") + '"></th>').join("") + "</tr>";
      grid.innerHTML = "<table><thead>" + head + "</thead><tbody></tbody></table>";
      const tbody = grid.querySelector("tbody");
      const paint = () => {
        const top = Math.max(0, Math.floor(grid.scrollTop / ROW) - 20);
        const count = Math.ceil(grid.clientHeight / ROW) + 40;
        const end = Math.min(rows.length, top + count);
        let html = '<tr style="height:' + top * ROW + 'px"></tr>';
        for (let r = top; r < end; r++) {
          html += '<tr data-row="' + r + '"' + (r === selected ? ' class="sel"' : "") + '><td class="dv-rownum">' + (r + 1) + "</td>";
          const row = rows[r];
          for (let c = 0; c < columns.length; c++) {
            const v = row[c];
            const cls = (v === null ? "null" : typeof v === "number" ? "num" : "") + (r === selected && c === currentColumn ? " cur" : "");
            html += '<td class="' + cls + '">' + (v === null ? "null" : esc(v)) + "</td>";
          }
          html += "</tr>";
        }
        html += '<tr style="height:' + (rows.length - end) * ROW + 'px"></tr>';
        tbody.innerHTML = html;
      };
      grid.onscroll = paint;
      paint();
      grid.querySelectorAll("thead tr:first-child th[data-col]").forEach((th) => th.addEventListener("click", () => {
        const name = columns[+th.dataset.col];
        if (sort.column !== name) sort = { column: name, desc: false };
        else if (!sort.desc) sort.desc = true;
        else sort = { column: null, desc: false };
        currentColumn = +th.dataset.col;
        run();
      }));
      grid.querySelectorAll("thead input").forEach((input) => {
        input.addEventListener("keydown", (e) => {
          if (e.key === "Enter") {
            filters[columns[+input.dataset.col]] = input.value;
            run();
          }
        });
        input.addEventListener("change", () => {
          filters[columns[+input.dataset.col]] = input.value;
          run();
        });
      });
      tbody.onclick = (e) => {
        const td = e.target.closest("td");
        const tr = e.target.closest("tr[data-row]");
        if (!tr) return;
        selected = +tr.dataset.row;
        currentColumn = td ? td.cellIndex - 1 : -1;
        paint();
        if (side.classList.contains("visible")) showSide();
      };
      tbody.ondblclick = () => {
        side.dataset.mode = "record";
        side.classList.add("visible");
        showSide();
      };
    }
    function showSide() {
      const mode = side.dataset.mode || "stats";
      const { columns, rows } = result;
      if (mode === "record") {
        if (selected < 0) {
          side.innerHTML = "<h4>Row</h4><p>Select a row.</p>";
          return;
        }
        const row = rows[selected];
        side.innerHTML = "<h4>Row " + (selected + 1) + "</h4><table>" + columns.map((c, i) => {
          let v = row[i];
          if (typeof v === "string" && /^[\[{]/.test(v)) {
            try {
              v = JSON.stringify(JSON.parse(v), null, 2);
            } catch (e) {
            }
          }
          return "<tr><td><b>" + esc(c) + "</b></td><td><pre>" + (v === null ? "<i>null</i>" : esc(v)) + "</pre></td></tr>";
        }).join("") + "</table>";
      } else if (mode === "schema") {
        side.innerHTML = isSQLite ? sqliteSchema() : parquetDetails || schemaPanel || "";
      } else {
        const column = columns[currentColumn >= 0 ? currentColumn : 0];
        if (!column) {
          side.innerHTML = "<h4>Column stats</h4><p>No column.</p>";
          return;
        }
        const sql = (sqlText.value || baseSQL).trim().replace(/;\s*$/, "");
        const w = where(columns);
        const from = "(SELECT * FROM (" + sql + ")" + w.sql + ")";
        const c = q(column);
        try {
          const s = db.exec("SELECT COUNT(*), COUNT(" + c + "), COUNT(DISTINCT " + c + "), MIN(" + c + "), MAX(" + c + "), AVG(CASE WHEN typeof(" + c + ") IN ('integer','real') THEN " + c + " END), SUM(CASE WHEN typeof(" + c + ") IN ('integer','real') THEN " + c + " END) FROM " + from, w.params)[0].values[0];
          const top = db.exec("SELECT " + c + ", COUNT(*) AS n FROM " + from + " GROUP BY " + c + " ORDER BY n DESC LIMIT 12", w.params)[0];
          const line = (k, v) => "<tr><td>" + k + "</td><td>" + (v === null || v === void 0 ? "\u2014" : esc(typeof v === "number" ? +v.toFixed(6) : v)) + "</td></tr>";
          side.innerHTML = "<h4>" + esc(column) + "</h4><table>" + line("Rows", s[0]) + line("Non-null", s[1]) + line("Nulls", s[0] - s[1]) + line("Distinct", s[2]) + line("Min", s[3]) + line("Max", s[4]) + line("Average", s[5]) + line("Sum", s[6]) + "</table><h4>Most common</h4><table>" + (top ? top.values.map((r) => line(r[0] === null ? "<i>null</i>" : esc(r[0]), r[1])).join("") : "") + '</table><p style="color:var(--text-secondary)">Click a column header or cell to choose the column.</p>';
        } catch (error) {
          side.innerHTML = "<p>" + esc(error.message) + "</p>";
        }
      }
    }
    function sqliteSchema() {
      const rows = db.exec("SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name")[0];
      return "<h4>Schema</h4>" + (rows ? rows.values.map((r) => "<p><b>" + esc(r[0]) + " " + esc(r[1]) + "</b></p><pre>" + esc(r[2] || "") + "</pre>").join("") : "<p>Empty database.</p>");
    }
    function toDelimited(sep) {
      const { columns, rows } = result;
      const cell = (v) => {
        if (v === null || v === void 0) return "";
        const s = String(v);
        if (sep === "	") return s.replace(/[\t\n\r]/g, " ");
        return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
      };
      return [columns.map(cell).join(sep)].concat(rows.map((r) => r.map(cell).join(sep))).join("\n") + "\n";
    }
    $(".dv-search").addEventListener("input", (e) => {
      search = e.target.value;
      clearTimeout(run.t);
      run.t = setTimeout(run, 200);
    });
    $(".dv-sqlbtn").addEventListener("click", () => {
      sqlBox.classList.toggle("visible");
      $(".dv-sqlbtn").classList.toggle("on", sqlBox.classList.contains("visible"));
      if (sqlBox.classList.contains("visible")) sqlText.focus();
    });
    $(".dv-run").addEventListener("click", () => {
      sort = { column: null, desc: false };
      run();
    });
    $(".dv-reset").addEventListener("click", () => {
      sqlText.value = baseSQL;
      sort = { column: null, desc: false };
      filters = {};
      search = "";
      $(".dv-search").value = "";
      run();
    });
    sqlText.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        sort = { column: null, desc: false };
        run();
      }
    });
    const toggleSide = (mode) => {
      const open = side.classList.contains("visible") && side.dataset.mode === mode;
      side.dataset.mode = mode;
      side.classList.toggle("visible", !open);
      if (!open) showSide();
    };
    $(".dv-stats").addEventListener("click", () => toggleSide("stats"));
    if ($(".dv-schema")) $(".dv-schema").addEventListener("click", () => toggleSide("schema"));
    $(".dv-export").addEventListener("click", () => {
      const blob = new Blob([toDelimited(",")], { type: "text/csv" });
      const a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = info.name.replace(/\.[^.]+$/, "") + "-export.csv";
      a.click();
      setTimeout(() => URL.revokeObjectURL(a.href), 5e3);
    });
    $(".dv-copy").addEventListener("click", () => navigator.clipboard.writeText(toDelimited("	")).then(() => say("Copied " + fmtCount(result.rows.length) + " rows.")));
    root.addEventListener("keydown", (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "c" && selected >= 0 && !/INPUT|TEXTAREA/.test(document.activeElement.tagName)) {
        const row = result.rows[selected];
        navigator.clipboard.writeText(currentColumn >= 0 ? String(row[currentColumn] ?? "") : row.map((v) => v ?? "").join("	"));
        e.preventDefault();
      }
    });
    root.tabIndex = -1;
    run();
    return {
      destroy() {
        try {
          db.close();
        } catch (e) {
        }
      },
      reload: null
      // tables are read once; reopen the tab to read changes
    };
  }
  function readWorkbook(bytes, lib) {
    const files = lib.unzip(bytes);
    const xml = (path) => files[path] ? new DOMParser().parseFromString(lib.text(files[path]), "application/xml") : null;
    const byTag = (node, tag) => node ? Array.from(node.getElementsByTagNameNS("*", tag)) : [];
    const shared = byTag(xml("xl/sharedStrings.xml"), "si").map((si) => byTag(si, "t").map((t) => t.textContent).join(""));
    const styles = xml("xl/styles.xml");
    const custom = {};
    byTag(styles, "numFmt").forEach((f) => {
      custom[f.getAttribute("numFmtId")] = f.getAttribute("formatCode") || "";
    });
    const cellXfs = styles ? byTag(byTag(styles, "cellXfs")[0], "xf") : [];
    const isDateStyle = cellXfs.map((xf) => {
      const id = +xf.getAttribute("numFmtId");
      if (id >= 14 && id <= 22 || id >= 45 && id <= 47) return true;
      const code = (custom[id] || "").replace(/"[^"]*"|\[[^\]]*\]/g, "");
      return /[dy]/i.test(code) || /m{1,4}.*[ds]|[hd].*m/i.test(code);
    });
    const toDate = (serial) => {
      const ms = Math.round((serial - 25569) * 864e5);
      const d = new Date(ms);
      return serial % 1 === 0 ? d.toISOString().slice(0, 10) : d.toISOString().replace("T", " ").slice(0, 19);
    };
    const rels = {};
    byTag(xml("xl/_rels/workbook.xml.rels"), "Relationship").forEach((r) => {
      rels[r.getAttribute("Id")] = r.getAttribute("Target");
    });
    const column = (ref) => {
      let n = 0;
      for (const ch of ref.replace(/\d+/g, "")) n = n * 26 + ch.charCodeAt(0) - 64;
      return n - 1;
    };
    return byTag(xml("xl/workbook.xml"), "sheet").map((sheet) => {
      const rid = sheet.getAttribute("r:id") || sheet.getAttributeNS("http://schemas.openxmlformats.org/officeDocument/2006/relationships", "id");
      let target = rels[rid] || "";
      target = target.startsWith("/") ? target.slice(1) : "xl/" + target.replace(/^\.\//, "");
      const grid = [];
      byTag(xml(target), "row").forEach((row) => {
        const cells = [];
        byTag(row, "c").forEach((c) => {
          const type = c.getAttribute("t");
          const v = byTag(c, "v")[0];
          let value = null;
          if (type === "s") value = v ? shared[+v.textContent] : null;
          else if (type === "inlineStr") value = byTag(c, "t").map((t) => t.textContent).join("");
          else if (type === "b") value = v ? v.textContent === "1" : null;
          else if (type === "str" || type === "e") value = v ? v.textContent : null;
          else if (v) {
            const n = Number(v.textContent);
            value = isDateStyle[+c.getAttribute("s") || 0] ? toDate(n) : n;
          }
          cells[column(c.getAttribute("r") || "A")] = value;
        });
        grid[(+row.getAttribute("r") || grid.length + 1) - 1] = cells;
      });
      return { name: sheet.getAttribute("name") || "Sheet", rows: gridObjects(grid.filter(Boolean)) };
    });
  }
  function gridObjects(rows) {
    const width = rows.reduce((m, r) => Math.max(m, r.length), 0);
    const letters = (i) => {
      let s = "";
      i++;
      while (i > 0) {
        const m = (i - 1) % 26;
        s = String.fromCharCode(65 + m) + s;
        i = Math.floor((i - m) / 26);
      }
      return s;
    };
    const first = rows[0] || [];
    const header = first.length && first.every((v) => typeof v === "string" && v.trim()) && new Set(first).size === first.length;
    const names = Array.from({ length: width }, (_, i) => header && first[i] ? first[i] : letters(i));
    return (header ? rows.slice(1) : rows).map((r) => {
      const o = {};
      names.forEach((n, i) => {
        o[n] = r[i] === void 0 ? null : r[i];
      });
      return o;
    });
  }
  function readOpenDocument(bytes, lib) {
    const files = lib.unzip(bytes);
    if (!files["content.xml"]) throw new Error("Not an OpenDocument spreadsheet (no content.xml).");
    const doc = new DOMParser().parseFromString(lib.text(files["content.xml"]), "application/xml");
    const TABLE = "urn:oasis:names:tc:opendocument:xmlns:table:1.0";
    const OFFICE = "urn:oasis:names:tc:opendocument:xmlns:office:1.0";
    const TEXT = "urn:oasis:names:tc:opendocument:xmlns:text:1.0";
    const children = (node, name) => Array.from(node.childNodes).filter((n) => n.namespaceURI === TABLE && n.localName === name);
    const rowsOf = (table) => {
      const out = [];
      const walk = (node) => {
        for (const child of Array.from(node.childNodes)) {
          if (child.namespaceURI !== TABLE) continue;
          if (child.localName === "table-row") out.push(child);
          else if (["table-rows", "table-header-rows", "table-row-group"].includes(child.localName)) walk(child);
        }
      };
      walk(table);
      return out;
    };
    return Array.from(doc.getElementsByTagNameNS(TABLE, "table")).map((table) => {
      const grid = [];
      for (const row of rowsOf(table)) {
        const cells = [];
        for (const cell of Array.from(row.childNodes).filter((n) => n.namespaceURI === TABLE && /table-cell$/.test(n.localName))) {
          const repeat = +cell.getAttributeNS(TABLE, "number-columns-repeated") || 1;
          const type = cell.getAttributeNS(OFFICE, "value-type");
          let value = null;
          if (type === "float" || type === "percentage" || type === "currency") value = Number(cell.getAttributeNS(OFFICE, "value"));
          else if (type === "date") value = (cell.getAttributeNS(OFFICE, "date-value") || "").replace("T00:00:00", "");
          else if (type === "boolean") value = cell.getAttributeNS(OFFICE, "boolean-value") === "true";
          else if (type === "time") value = cell.getAttributeNS(OFFICE, "time-value");
          else {
            const text = Array.from(cell.getElementsByTagNameNS(TEXT, "p")).map((p) => p.textContent).join("\n");
            value = text === "" ? null : text;
          }
          for (let k = 0; k < (value === null ? Math.min(repeat, 1) : Math.min(repeat, 1e3)); k++) cells.push(value);
        }
        while (cells.length && cells[cells.length - 1] === null) cells.pop();
        const repeatRows = +row.getAttributeNS(TABLE, "number-rows-repeated") || 1;
        for (let k = 0; k < (cells.length ? Math.min(repeatRows, 1e3) : 1); k++) grid.push(cells);
      }
      while (grid.length && !grid[grid.length - 1].length) grid.pop();
      return { name: table.getAttributeNS(TABLE, "name") || "Sheet", rows: gridObjects(grid.filter((r) => r.length)) };
    });
  }
  function readArrow(bytes, lib) {
    const table = lib.arrowTable(bytes);
    const names = table.schema.fields.map((f) => f.name);
    const limit = Math.min(table.numRows, 5e5);
    const columns = names.map((_, i) => table.getChildAt(i));
    const rows = new Array(limit);
    for (let r = 0; r < limit; r++) {
      const o = {};
      for (let c = 0; c < names.length; c++) {
        let v = columns[c] ? columns[c].get(r) : null;
        if (v && typeof v === "object" && typeof v.toJSON === "function" && !(v instanceof Date)) v = v.toJSON();
        const type = String(table.schema.fields[c].type);
        if (typeof v === "number" && /^Timestamp|^Date/.test(type)) v = new Date(v);
        o[names[c]] = v;
      }
      rows[r] = o;
    }
    const schema = "<h4>Arrow schema</h4><table>" + table.schema.fields.map((f) => "<tr><td>" + esc(f.name) + "</td><td>" + esc(String(f.type)) + (f.nullable ? " \xB7 nullable" : "") + "</td></tr>").join("") + "</table><p>" + fmtCount(table.numRows) + " rows" + (table.numRows > limit ? " (first " + fmtCount(limit) + " shown)" : "") + ", " + table.batches.length + " record batches</p>";
    return { rows, schema };
  }
  function readAvro(bytes, lib) {
    if (!(bytes[0] === 79 && bytes[1] === 98 && bytes[2] === 106 && bytes[3] === 1)) throw new Error("Not an Avro object container file.");
    const utf8 = new TextDecoder();
    function Reader(buf) {
      this.buf = buf;
      this.p = 0;
      this.view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
    }
    Reader.prototype.long = function() {
      let n = 0, scale = 1, b;
      do {
        b = this.buf[this.p++];
        n += (b & 127) * scale;
        scale *= 128;
      } while (b & 128);
      return n % 2 === 0 ? n / 2 : -(n + 1) / 2;
    };
    Reader.prototype.bytes = function() {
      const n = this.long();
      const out = this.buf.subarray(this.p, this.p + n);
      this.p += n;
      return out;
    };
    Reader.prototype.string = function() {
      return utf8.decode(this.bytes());
    };
    const header = new Reader(bytes);
    header.p = 4;
    const meta = {};
    for (let count = header.long(); count !== 0; count = header.long()) {
      if (count < 0) {
        count = -count;
        header.long();
      }
      for (let i = 0; i < count; i++) {
        const key = header.string();
        meta[key] = header.bytes();
      }
    }
    const schemaText = utf8.decode(meta["avro.schema"] || new Uint8Array());
    const schema = JSON.parse(schemaText);
    const codec = meta["avro.codec"] ? utf8.decode(meta["avro.codec"]) : "null";
    const sync = bytes.subarray(header.p, header.p + 16);
    header.p += 16;
    const named = {};
    const register = (type, namespace) => {
      if (Array.isArray(type)) {
        type.forEach((t) => register(t, namespace));
        return;
      }
      if (!type || typeof type !== "object") return;
      const ns = type.namespace || namespace;
      if (type.name && ["record", "error", "enum", "fixed"].includes(type.type)) {
        named[type.name] = type;
        if (ns && !type.name.includes(".")) named[ns + "." + type.name] = type;
      }
      if (type.fields) type.fields.forEach((f) => register(f.type, ns));
      if (type.items) register(type.items, ns);
      if (type.values) register(type.values, ns);
    };
    register(schema, schema.namespace);
    const iso = (ms) => new Date(ms).toISOString();
    function read(type, r) {
      if (typeof type === "string") {
        switch (type) {
          case "null":
            return null;
          case "boolean":
            return r.buf[r.p++] !== 0;
          case "int":
          case "long":
            return r.long();
          case "float": {
            const v = r.view.getFloat32(r.p, true);
            r.p += 4;
            return v;
          }
          case "double": {
            const v = r.view.getFloat64(r.p, true);
            r.p += 8;
            return v;
          }
          case "bytes":
            return r.bytes();
          case "string":
            return r.string();
          default:
            if (named[type]) return read(named[type], r);
            throw new Error("Unknown Avro type " + type);
        }
      }
      if (Array.isArray(type)) return read(type[r.long()], r);
      const logical = type.logicalType;
      switch (type.type) {
        case "record":
        case "error": {
          const o = {};
          for (const field of type.fields) o[field.name] = read(field.type, r);
          return o;
        }
        case "enum":
          return type.symbols[r.long()];
        case "array": {
          const out = [];
          for (let count = r.long(); count !== 0; count = r.long()) {
            if (count < 0) {
              count = -count;
              r.long();
            }
            for (let i = 0; i < count; i++) out.push(read(type.items, r));
          }
          return out;
        }
        case "map": {
          const out = {};
          for (let count = r.long(); count !== 0; count = r.long()) {
            if (count < 0) {
              count = -count;
              r.long();
            }
            for (let i = 0; i < count; i++) {
              const key = r.string();
              out[key] = read(type.values, r);
            }
          }
          return out;
        }
        case "fixed": {
          const out = r.buf.subarray(r.p, r.p + type.size);
          r.p += type.size;
          return logical === "decimal" ? decimal(out, type.scale) : out;
        }
        default: {
          const v = read(type.type, r);
          if (logical === "date" && typeof v === "number") return iso(v * 864e5).slice(0, 10);
          if (logical === "timestamp-millis" || logical === "local-timestamp-millis") return iso(v);
          if (logical === "timestamp-micros" || logical === "local-timestamp-micros") return iso(v / 1e3);
          if (logical === "time-millis") return new Date(v).toISOString().slice(11, 23);
          if (logical === "decimal" && v instanceof Uint8Array) return decimal(v, type.scale);
          return v;
        }
      }
    }
    function decimal(bytesValue, scale) {
      let n = 0n;
      for (const b of bytesValue) n = n << 8n | BigInt(b);
      if (bytesValue.length && bytesValue[0] & 128) n -= 1n << BigInt(bytesValue.length * 8);
      const negative = n < 0n;
      let digits = (negative ? -n : n).toString().padStart((scale || 0) + 1, "0");
      if (scale) digits = digits.slice(0, -scale) + "." + digits.slice(-scale);
      return (negative ? "-" : "") + digits;
    }
    const rows = [];
    while (header.p < bytes.length && rows.length < 5e5) {
      const count = header.long();
      const size = header.long();
      let block = bytes.subarray(header.p, header.p + size);
      header.p += size + 16;
      if (codec === "deflate") block = lib.inflate(block);
      else if (codec === "snappy") {
        const data = block.subarray(0, block.length - 4);
        let length = 0, scale = 1, k = 0, b;
        do {
          b = data[k++];
          length += (b & 127) * scale;
          scale *= 128;
        } while (b & 128);
        block = lib.snappy(data, length);
      } else if (codec !== "null") throw new Error("Avro codec " + codec + " is not supported (null, deflate and snappy are).");
      const r = new Reader(block);
      for (let i = 0; i < count; i++) {
        const value = read(schema, r);
        rows.push(value && typeof value === "object" && !Array.isArray(value) && !(value instanceof Uint8Array) ? flatten(value) : { value });
      }
    }
    void sync;
    return { rows, codec, schema: "<h4>Avro schema</h4><pre>" + esc(JSON.stringify(schema, null, 2)) + "</pre>" };
  }
  function describeParquet(metadata, lib) {
    const schema = lib.parquet.schema(metadata);
    const codecs = /* @__PURE__ */ new Set();
    metadata.row_groups.forEach((g) => g.columns.forEach((c) => c.meta_data && codecs.add(c.meta_data.codec)));
    const fields = (schema.children || []).map((child) => {
      const el = child.element;
      const type = el.logical_type ? el.logical_type.type || JSON.stringify(el.logical_type) : el.converted_type || el.type || (child.children && child.children.length ? "group" : "");
      return "<tr><td>" + esc(el.name) + "</td><td>" + esc(String(type)) + (el.repetition_type === "OPTIONAL" ? " \xB7 nullable" : el.repetition_type === "REPEATED" ? " \xB7 repeated" : "") + "</td></tr>";
    }).join("");
    const kv = (metadata.key_value_metadata || []).filter((e) => e.key !== "ARROW:schema").map((e) => "<tr><td>" + esc(e.key) + "</td><td><pre>" + esc(String(e.value || "").slice(0, 2e3)) + "</pre></td></tr>").join("");
    return "<h4>Parquet</h4><table><tr><td>Rows</td><td>" + fmtCount(Number(metadata.num_rows)) + "</td></tr><tr><td>Row groups</td><td>" + metadata.row_groups.length + "</td></tr><tr><td>Compression</td><td>" + esc([...codecs].join(", ") || "\u2014") + "</td></tr><tr><td>Format version</td><td>" + esc(String(metadata.version)) + "</td></tr><tr><td>Created by</td><td>" + esc(metadata.created_by || "\u2014") + "</td></tr></table><h4>Columns</h4><table>" + fields + "</table>" + (kv ? "<h4>Metadata</h4><table>" + kv + "</table>" : "");
  }
  const LEVELS = ["fatal", "error", "warn", "info", "debug", "trace", "other"];
  const LEVEL_WORDS = /\b(FATAL|CRITICAL|CRIT|EMERG(?:ENCY)?|ALERT|ERROR|ERR|SEVERE|WARN(?:ING)?|NOTICE|INFO|DEBUG|DBG|TRACE|VERBOSE)\b/i;
  const TIMESTAMP = /^(\[?\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?\]?|\[?\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2}[^\]]*\]?|\w{3} [ \d]\d \d{2}:\d{2}:\d{2}|\d{2}:\d{2}:\d{2}(?:[.,]\d+)?)/;
  function levelOf(word) {
    const w = word.toLowerCase();
    if (/fatal|crit|emerg|alert/.test(w)) return "fatal";
    if (/err|severe/.test(w)) return "error";
    if (/warn/.test(w)) return "warn";
    if (/info|notice/.test(w)) return "info";
    if (/debug|dbg/.test(w)) return "debug";
    if (/trace|verbose/.test(w)) return "trace";
    return "other";
  }
  function analyseLog(text) {
    const raw = text.split(/\r?\n/);
    if (raw.length && raw[raw.length - 1] === "") raw.pop();
    const lines = new Array(raw.length);
    let previous = "other";
    for (let i = 0; i < raw.length; i++) {
      const t = raw[i];
      let level = null;
      if (t.charCodeAt(0) === 123) {
        try {
          const o = JSON.parse(t);
          const v = o.level ?? o.severity ?? o.lvl ?? o.levelname ?? o.log_level ?? (o.log && o.log.level);
          if (typeof v === "string") level = levelOf(v);
          else if (typeof v === "number") level = v >= 60 ? "fatal" : v >= 50 ? "error" : v >= 40 ? "warn" : v >= 30 ? "info" : v >= 20 ? "debug" : "trace";
        } catch (e) {
        }
      }
      if (!level) {
        const m = t.slice(0, 200).match(LEVEL_WORDS);
        if (m) level = levelOf(m[1]);
        else if (/^\s+(at |\.\.\.|Caused by)|^\s{2,}\S|^Traceback|^\s*File "/.test(t)) level = previous;
        else level = "other";
      }
      previous = level;
      lines[i] = { text: t, level };
    }
    return lines;
  }
  function LogViewer(root, name, bytes) {
    let lines = analyseLog(decodeText(bytes));
    const show = { fatal: true, error: true, warn: true, info: true, debug: true, trace: true, other: true };
    let query = "", regex = false, caseSensitive = false, onlyMatches = false, wrap2 = false, follow = false;
    let visible = [];
    let matches = [];
    let currentMatch = -1, cursor = -1;
    const H = 18;
    root.innerHTML = `
          <div class="dv-bar">
            <span class="dv-title">${esc(name)}</span><span class="dv-meta dv-count"></span>
            <span class="dv-level"></span>
            <span class="dv-spacer"></span>
            <input type="search" class="dv-q" placeholder="Search (\u2318F)">
            <button class="dv-btn dv-re" title="Regular expression">.*</button>
            <button class="dv-btn dv-case" title="Match case">Aa</button>
            <button class="dv-btn dv-only" title="Show only matching lines">Only matches</button>
            <button class="dv-btn dv-prev" title="Previous match (\u21E7\u21A9)">\u2191</button>
            <button class="dv-btn dv-next" title="Next match (\u21A9)">\u2193</button>
            <span class="dv-meta dv-mcount"></span>
            <button class="dv-btn dv-err" title="Next error or fatal line">Next error</button>
            <button class="dv-btn dv-wrap">Wrap</button>
            <button class="dv-btn dv-follow" title="Follow the end of the file as it grows">Follow</button>
          </div>
          <div class="dv-msg"></div>
          <div class="dv-body"><div class="dv-log"></div><div class="dv-side"></div></div>`;
    const $ = (s) => root.querySelector(s);
    const view = $(".dv-log"), side = $(".dv-side"), msg = $(".dv-msg");
    function pattern() {
      if (!query) return null;
      try {
        return new RegExp(regex ? query : query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), caseSensitive ? "g" : "gi");
      } catch (e) {
        msg.textContent = "Regular expression: " + e.message;
        msg.classList.add("error");
        return null;
      }
    }
    function levelBar() {
      const counts = {};
      LEVELS.forEach((l) => counts[l] = 0);
      lines.forEach((l) => counts[l.level]++);
      $(".dv-level").innerHTML = LEVELS.filter((l) => counts[l] > 0).map((l) => '<button class="dv-btn' + (show[l] ? " on" : "") + '" data-level="' + l + '">' + l[0].toUpperCase() + l.slice(1) + '<span class="n">' + fmtCount(counts[l]) + "</span></button>").join("");
      $(".dv-level").querySelectorAll("button").forEach((b) => b.addEventListener("click", (e) => {
        const l = b.dataset.level;
        if (e.altKey) LEVELS.forEach((x) => show[x] = x === l);
        else show[l] = !show[l];
        refilter();
        levelBar();
      }));
    }
    function refilter(keepScroll) {
      msg.textContent = "";
      msg.classList.remove("error");
      const re = pattern();
      visible = [];
      matches = [];
      for (let i = 0; i < lines.length; i++) {
        if (!show[lines[i].level]) continue;
        let hit = false;
        if (re) {
          re.lastIndex = 0;
          hit = re.test(lines[i].text);
        }
        if (onlyMatches && re && !hit) continue;
        if (hit) matches.push(visible.length);
        visible.push(i);
      }
      $(".dv-count").textContent = fmtCount(lines.length) + " lines" + (visible.length !== lines.length ? " \xB7 " + fmtCount(visible.length) + " shown" : "");
      $(".dv-mcount").textContent = re ? fmtCount(matches.length) + " matches" : "";
      if (currentMatch >= matches.length) currentMatch = -1;
      paint(true);
      if (follow) view.scrollTop = view.scrollHeight;
      else if (!keepScroll && matches.length && re) goMatch(0);
    }
    function highlight(text, re) {
      if (!re) return tsMark(esc(text));
      let out = "", last = 0, m;
      re.lastIndex = 0;
      while ((m = re.exec(text)) && m[0].length) {
        out += esc(text.slice(last, m.index)) + "<mark>" + esc(m[0]) + "</mark>";
        last = m.index + m[0].length;
      }
      return out + esc(text.slice(last));
    }
    function tsMark(html) {
      const m = html.match(TIMESTAMP);
      return m ? '<span class="ts">' + m[0] + "</span>" + html.slice(m[0].length) : html;
    }
    function lineHTML(position) {
      const index = visible[position];
      const line = lines[index];
      return '<div class="ln ' + line.level + (position === cursor ? " cur" : "") + '" data-pos="' + position + '"><span class="no">' + (index + 1) + '</span><span class="tx">' + highlight(line.text.length > 5e3 ? line.text.slice(0, 5e3) + "\u2026" : line.text, pattern()) + "</span></div>";
    }
    function paint() {
      if (wrap2) {
        const cap = Math.min(visible.length, 2e4);
        let html2 = "";
        for (let p = 0; p < cap; p++) html2 += lineHTML(p);
        if (visible.length > cap) html2 += '<div class="ln"><span class="no"></span><span class="tx">\u2026 ' + fmtCount(visible.length - cap) + " more lines: turn Wrap off to see them</span></div>";
        view.innerHTML = html2;
        return;
      }
      const top = Math.max(0, Math.floor(view.scrollTop / H) - 30);
      const end = Math.min(visible.length, top + Math.ceil(view.clientHeight / H) + 60);
      let html = '<div style="height:' + top * H + 'px"></div>';
      for (let p = top; p < end; p++) html += lineHTML(p);
      html += '<div style="height:' + (visible.length - end) * H + 'px"></div>';
      view.innerHTML = html;
    }
    function scrollToPosition(position) {
      cursor = position;
      if (wrap2) {
        paint();
        const el = view.querySelector('[data-pos="' + position + '"]');
        if (el) el.scrollIntoView({ block: "center" });
        return;
      }
      view.scrollTop = Math.max(0, position * H - view.clientHeight / 2);
      paint();
    }
    function goMatch(delta) {
      if (!matches.length) return;
      currentMatch = currentMatch < 0 ? delta >= 0 ? 0 : matches.length - 1 : (currentMatch + delta + matches.length) % matches.length;
      if (delta === 0) currentMatch = 0;
      $(".dv-mcount").textContent = currentMatch + 1 + " / " + fmtCount(matches.length);
      scrollToPosition(matches[currentMatch]);
    }
    function nextError() {
      const start = cursor + 1;
      for (let k = 0; k < visible.length; k++) {
        const p = (start + k) % visible.length;
        const level = lines[visible[p]].level;
        if (level === "error" || level === "fatal") {
          scrollToPosition(p);
          return;
        }
      }
      msg.textContent = "No error lines among those shown.";
    }
    function showLine(position) {
      const line = lines[visible[position]];
      let body = esc(line.text);
      const brace = line.text.indexOf("{");
      if (brace >= 0) {
        try {
          body = esc(JSON.stringify(JSON.parse(line.text.slice(brace)), null, 2));
        } catch (e) {
        }
      }
      side.innerHTML = "<h4>Line " + (visible[position] + 1) + " \xB7 " + line.level + "</h4><pre>" + body + "</pre>";
      side.classList.add("visible");
    }
    view.addEventListener("scroll", () => {
      if (!wrap2) paint();
    });
    view.addEventListener("click", (e) => {
      const ln = e.target.closest(".ln[data-pos]");
      if (!ln) return;
      cursor = +ln.dataset.pos;
      paint();
      showLine(cursor);
    });
    const q2 = $(".dv-q");
    q2.addEventListener("input", () => {
      query = q2.value;
      currentMatch = -1;
      clearTimeout(q2.t);
      q2.t = setTimeout(() => refilter(), 200);
    });
    q2.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        goMatch(e.shiftKey ? -1 : 1);
      }
    });
    const toggle = (sel, get, set) => $(sel).addEventListener("click", () => {
      set(!get());
      $(sel).classList.toggle("on", get());
      refilter(true);
    });
    toggle(".dv-re", () => regex, (v) => regex = v);
    toggle(".dv-case", () => caseSensitive, (v) => caseSensitive = v);
    toggle(".dv-only", () => onlyMatches, (v) => onlyMatches = v);
    $(".dv-prev").addEventListener("click", () => goMatch(-1));
    $(".dv-next").addEventListener("click", () => goMatch(1));
    $(".dv-err").addEventListener("click", nextError);
    $(".dv-wrap").addEventListener("click", () => {
      wrap2 = !wrap2;
      view.classList.toggle("wrap", wrap2);
      $(".dv-wrap").classList.toggle("on", wrap2);
      paint();
    });
    $(".dv-follow").addEventListener("click", () => {
      follow = !follow;
      $(".dv-follow").classList.toggle("on", follow);
      if (follow) view.scrollTop = view.scrollHeight;
    });
    const findKey = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "f" && container.classList.contains("visible")) {
        e.preventDefault();
        e.stopPropagation();
        q2.focus();
        q2.select();
      }
    };
    document.addEventListener("keydown", findKey, true);
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
      destroy() {
        document.removeEventListener("keydown", findKey, true);
      }
    };
  }
  const wrap = (name) => {
    const original = window[name];
    if (typeof original !== "function") return;
    window[name] = function() {
      window.leaveDataView();
      return original.apply(this, arguments);
    };
  };
  ["setContent", "setStructuredContent", "setCodeContent"].forEach(wrap);
  window.MVDataViewers = { analyseLog, parseText, loadRows, cellValue };
})();
;
(function(root, factory) {
  "use strict";
  var api = factory();
  if (typeof module === "object" && module && module.exports) module.exports = api;
  if (typeof window !== "undefined" && root === window) window.MVResearchMapLayout = api;
})(typeof window !== "undefined" ? window : this, function() {
  "use strict";
  var PRESETS = ["balanced", "right", "left", "down", "up", "radial", "outline"];
  var D = {
    level: 56,
    // free space between a node and its children's boxes, along the growth axis
    minStepX: 230,
    // smallest centre-to-centre step of a horizontal tree (the prototype's level spacing)
    minStepY: 112,
    // the same for vertical trees
    siblingV: 40,
    // space between stacked siblings of a horizontal tree
    siblingH: 36,
    // space between side-by-side siblings of a vertical tree
    sideSlack: 90,
    // balanced layout: how much taller the alternate side may be before a branch goes to the lighter one
    rowGap: 14,
    // outline row spacing
    indent: 40,
    // outline indent per level
    ringGap: 28,
    // free space between boxes on a radial layout
    ring1: 170,
    // smallest radius of the first ring
    ringStep: 150
    // smallest distance between rings
  };
  function isManual(node) {
    return !!node && typeof node.x === "number" && isFinite(node.x) && typeof node.y === "number" && isFinite(node.y);
  }
  function positive(value) {
    return typeof value === "number" && isFinite(value) && value > 0 ? value : 0;
  }
  function estimateSize(node, isRoot) {
    var title = String(node && node.title || "");
    var givenW = positive(node && node.width), givenH = positive(node && node.height);
    var shape = node && node.shape;
    var fit = shape === "ellipse" ? Math.SQRT1_2 : shape === "diamond" ? 0.5 : 0;
    var font = isRoot ? 16 : 14;
    var charWidth = font * 0.6;
    var padX = fit ? 24 : 52;
    var minW = isRoot ? 170 : 110;
    var maxW = 220;
    var avail = givenW ? givenW * (fit || 1) : fit ? (shape === "diamond" ? 130 : 170) + padX : maxW;
    var perLine = Math.max(4, Math.floor((avail - padX) / charWidth));
    var words = title.split(/\s+/).filter(Boolean);
    var lines = [], line = "";
    words.forEach(function(word) {
      while (word.length > perLine) {
        if (line) {
          lines.push(line);
          line = "";
        }
        lines.push(word.slice(0, perLine));
        word = word.slice(perLine);
      }
      if (!line) line = word;
      else if ((line + " " + word).length <= perLine) line += " " + word;
      else {
        lines.push(line);
        line = word;
      }
    });
    if (line || !lines.length) lines.push(line);
    var widest = lines.reduce(function(m, l) {
      return Math.max(m, l.length);
    }, 0);
    var w, h;
    if (fit) {
      w = Math.max(shape === "diamond" ? 112 : 88, Math.round(widest * charWidth / fit) + padX);
      h = Math.max(shape === "diamond" ? 68 : 46, Math.round(lines.length * font * 1.3 / fit) + 12);
    } else {
      w = Math.min(maxW, Math.max(minW, Math.round(widest * charWidth + padX)));
      h = Math.round(lines.length * font * 1.3 + (isRoot ? 40 : 26));
    }
    if (givenW) w = givenW;
    if (givenH) h = Math.max(h, givenH);
    return { w, h };
  }
  function validPresets(layouts) {
    var set = new Set(PRESETS);
    if (Array.isArray(layouts) && layouts.length) {
      var listed = new Set(layouts.map(function(l) {
        return l && l.id;
      }));
      PRESETS.forEach(function(id) {
        if (!listed.has(id)) set.delete(id);
      });
    }
    return set;
  }
  function rect(item) {
    return { l: -item.w / 2, t: -item.h / 2, r: item.w / 2, b: item.h / 2 };
  }
  function shift(b, dx, dy) {
    return { l: b.l + dx, t: b.t + dy, r: b.r + dx, b: b.b + dy };
  }
  function union(a, b) {
    if (!a) return b;
    if (!b) return a;
    return { l: Math.min(a.l, b.l), t: Math.min(a.t, b.t), r: Math.max(a.r, b.r), b: Math.max(a.b, b.b) };
  }
  function touches(a, b, gap) {
    return a.l < b.r + gap && b.l < a.r + gap && a.t < b.b + gap && b.t < a.b + gap;
  }
  function toAxis(b, dir) {
    if (dir === "right") return { g0: b.l, g1: b.r, c0: b.t, c1: b.b };
    if (dir === "left") return { g0: -b.r, g1: -b.l, c0: b.t, c1: b.b };
    if (dir === "down") return { g0: b.t, g1: b.b, c0: b.l, c1: b.r };
    return { g0: -b.b, g1: -b.t, c0: b.l, c1: b.r };
  }
  function fromAxis(g, c, dir) {
    if (dir === "right") return { x: g, y: c };
    if (dir === "left") return { x: -g, y: c };
    if (dir === "down") return { x: c, y: g };
    return { x: c, y: -g };
  }
  function build(opts) {
    var list = Array.isArray(opts.nodes) ? opts.nodes : [];
    var valid = validPresets(opts.layouts);
    var byId = /* @__PURE__ */ new Map(), items = [];
    list.forEach(function(node) {
      if (!node || node.id == null) return;
      var id = String(node.id);
      if (byId.has(id)) return;
      var item = {
        id,
        node,
        kids: [],
        parent: null,
        parentId: node.parent == null ? "" : String(node.parent),
        own: typeof node.layout === "string" && valid.has(node.layout) ? node.layout : null,
        eff: null,
        manual: isManual(node),
        x: Number(node.x),
        y: Number(node.y),
        w: 0,
        h: 0,
        rel: { x: 0, y: 0 },
        box: null
      };
      byId.set(id, item);
      items.push(item);
    });
    if (!items.length) return null;
    var top = items.filter(function(i) {
      return i.parentId === "";
    })[0] || items[0];
    items.forEach(function(item) {
      if (item === top) return;
      var parent = byId.get(item.parentId);
      item.parent = parent && parent !== item ? parent : top;
      item.parent.kids.push(item);
    });
    var reached = /* @__PURE__ */ new Set();
    function walk(start) {
      var stack = [start];
      while (stack.length) {
        var cur = stack.pop();
        if (reached.has(cur)) continue;
        reached.add(cur);
        for (var k = cur.kids.length - 1; k >= 0; k--) stack.push(cur.kids[k]);
      }
    }
    walk(top);
    items.forEach(function(item) {
      if (reached.has(item)) return;
      if (item.parent) item.parent.kids = item.parent.kids.filter(function(k) {
        return k !== item;
      });
      item.parent = top;
      top.kids.push(item);
      walk(item);
    });
    var order = [];
    (function pre(start) {
      var stack = [start];
      while (stack.length) {
        var cur = stack.pop();
        order.push(cur);
        for (var k = cur.kids.length - 1; k >= 0; k--) stack.push(cur.kids[k]);
      }
    })(top);
    order.forEach(function(item) {
      item.eff = item.own || (item.parent ? item.parent.eff : "balanced");
    });
    return { root: top, items, order, byId };
  }
  function arrange(item, mode) {
    var box = rect(item);
    if (item.kids.length) {
      if (mode === "radial") box = arrangeRadial(item);
      else if (mode === "outline") box = arrangeOutline(item);
      else if (mode === "balanced") {
        var sides = splitSides(item);
        box = union(box, placeLinear(item, sides.right, "right"));
        box = union(box, placeLinear(item, sides.left, "left"));
      } else box = union(box, placeLinear(item, item.kids, mode));
    }
    item.box = box;
    return box;
  }
  function splitSides(item) {
    var right = [], left = [], total = { right: 0, left: 0 }, previous = "left";
    item.kids.forEach(function(kid) {
      var box = arrange(kid, kid.own || "right");
      var weight = box.b - box.t + D.siblingV;
      var side = previous === "left" ? "right" : "left", other = side === "right" ? "left" : "right";
      if (total[side] - total[other] > D.sideSlack) side = other;
      (side === "right" ? right : left).push(kid);
      total[side] += weight;
      previous = side;
    });
    return { right, left };
  }
  function placeLinear(item, kids, dir) {
    if (!kids.length) return null;
    var horizontal = dir === "right" || dir === "left";
    var gap = horizontal ? D.siblingV : D.siblingH;
    var nodeG = (horizontal ? item.w : item.h) / 2;
    var rows = kids.map(function(kid) {
      return { kid, a: toAxis(arrange(kid, kid.own || dir), dir), c: 0 };
    });
    var step = horizontal ? D.minStepX : D.minStepY;
    rows.forEach(function(row) {
      step = Math.max(step, nodeG + D.level - row.a.g0);
    });
    var cursor = 0;
    rows.forEach(function(row) {
      row.c = cursor - row.a.c0;
      cursor += row.a.c1 - row.a.c0 + gap;
    });
    var mid = (rows[0].c + rows[rows.length - 1].c) / 2;
    var out = null;
    rows.forEach(function(row) {
      var p = fromAxis(step, row.c - mid, dir);
      row.kid.rel = p;
      out = union(out, shift(row.kid.box, p.x, p.y));
    });
    return out;
  }
  function arrangeOutline(item) {
    var box = rect(item);
    var cursor = item.h / 2 + D.rowGap;
    item.kids.forEach(function(kid) {
      var kb = arrange(kid, kid.own || "outline");
      var p = { x: -item.w / 2 + D.indent - kb.l, y: cursor - kb.t };
      kid.rel = p;
      box = union(box, shift(kb, p.x, p.y));
      cursor += kb.b - kb.t + D.rowGap;
    });
    return box;
  }
  function arrangeRadial(owner) {
    var top = { item: owner, parent: null, depth: 0, kids: [], off: { x: 0, y: 0 } };
    var members = [];
    (function grow(m) {
      m.item.kids.forEach(function(kid) {
        var km = { item: kid, parent: m, depth: m.depth + 1, kids: [], atom: !!kid.own, off: null, angle: 0, weight: 1 };
        m.kids.push(km);
        members.push(km);
        if (km.atom) {
          km.box = arrange(kid, kid.own);
          km.weight = Math.max(1, Math.round(Math.max(km.box.r - km.box.l, km.box.b - km.box.t) / 200));
        } else {
          km.box = rect(kid);
          grow(km);
          km.weight = km.kids.length ? km.kids.reduce(function(s, k2) {
            return s + k2.weight;
          }, 0) : 1;
        }
      });
    })(top);
    var total = top.kids.reduce(function(s, k2) {
      return s + k2.weight;
    }, 0);
    var full = Math.PI * 2;
    function assign(m, a0, a1) {
      var sum = m.kids.reduce(function(s, k2) {
        return s + k2.weight;
      }, 0);
      var a = a0;
      m.kids.forEach(function(k2) {
        var span = (a1 - a0) * k2.weight / sum;
        k2.angle = a + span / 2;
        assign(k2, a, a + span);
        a += span;
      });
    }
    var firstSpan = full * top.kids[0].weight / total;
    assign(top, -firstSpan / 2, full - firstSpan / 2);
    var placed = [rect(owner)];
    var maxDepth = members.reduce(function(m, k2) {
      return Math.max(m, k2.depth);
    }, 0);
    var previous = 0;
    for (var depth = 1; depth <= maxDepth; depth++) {
      var ring = members.filter(function(m) {
        return m.depth === depth;
      });
      var r = Math.max(previous + D.ringStep, depth === 1 ? D.ring1 : 0);
      for (var guard = 0; guard < 6e3; guard++) {
        ring.forEach(function(m) {
          m.off = { x: Math.cos(m.angle) * r, y: Math.sin(m.angle) * r };
          m.rect = shift(m.box, m.off.x, m.off.y);
        });
        var clash = false;
        for (var i = 0; i < ring.length && !clash; i++) {
          for (var j = 0; j < placed.length && !clash; j++) if (touches(ring[i].rect, placed[j], D.ringGap)) clash = true;
          for (var k = 0; k < i && !clash; k++) if (touches(ring[i].rect, ring[k].rect, D.ringGap)) clash = true;
        }
        if (!clash) break;
        r += 10 + Math.floor(guard / 60) * 10;
      }
      ring.forEach(function(m) {
        placed.push(m.rect);
      });
      previous = r;
    }
    var box = rect(owner);
    members.forEach(function(m) {
      var parentOff = m.parent.off;
      m.item.rel = { x: m.off.x - parentOff.x, y: m.off.y - parentOff.y };
      box = union(box, m.rect);
    });
    return box;
  }
  function sizeOf(opts, item, isRoot) {
    var s = null;
    try {
      s = typeof opts.size === "function" ? opts.size(item.node) : null;
    } catch (e) {
      s = null;
    }
    if (!s || !(s.w > 0) || !(s.h > 0) || !isFinite(s.w) || !isFinite(s.h)) s = estimateSize(item.node, isRoot);
    return s;
  }
  function compute(opts) {
    opts = opts || {};
    var model = build(opts);
    if (!model) return { positions: {}, bounds: { l: 0, t: 0, r: 0, b: 0 } };
    model.items.forEach(function(item) {
      var s = sizeOf(opts, item, item === model.root);
      item.w = s.w;
      item.h = s.h;
    });
    arrange(model.root, model.root.eff);
    var abs = /* @__PURE__ */ new Map();
    var positions = {}, bounds = null;
    model.order.forEach(function(item) {
      var base = item.parent ? abs.get(item.parent) : { x: 0, y: 0 };
      var p = item.manual ? { x: item.x, y: item.y } : { x: base.x + item.rel.x, y: base.y + item.rel.y };
      abs.set(item, p);
      var out = item.manual ? { x: p.x, y: p.y } : { x: Math.round(p.x) || 0, y: Math.round(p.y) || 0 };
      positions[item.id] = out;
      bounds = union(bounds, { l: out.x - item.w / 2, t: out.y - item.h / 2, r: out.x + item.w / 2, b: out.y + item.h / 2 });
    });
    return { positions, bounds };
  }
  function effectiveLayout(nodes, id, layouts) {
    var model = build({ nodes, layouts });
    if (!model) return "balanced";
    var item = model.byId.get(String(id));
    return item ? item.eff : "balanced";
  }
  return { PRESETS, compute, effectiveLayout, estimateSize, isManual };
});
;
(function(A) {
  "use strict";
  Object.assign(A, {
    clamp,
    diagramSourceOf,
    fillVisual,
    flushAll,
    flushUpdate,
    h,
    icon,
    imageOf,
    imageURL,
    isResearchMapText,
    loadSaved,
    mix,
    now,
    queueMove,
    queueUpdate,
    readableOn,
    reportError,
    saveNow,
    saveSoon,
    send,
    setGlyph,
    setThumb,
    visualOf,
    withDiagram,
    withImage
  });
  const Layout = window.MVResearchMapLayout;
  A.Layout = Layout;
  const host = document.querySelector(".editor-content");
  A.host = host;
  if (!Layout || !host || typeof DOM === "undefined" || typeof state === "undefined") return;
  A.ready = true;
  const NS = "http://www.w3.org/2000/svg";
  A.NS = NS;
  const BRANCH_COLOURS = 6;
  A.BRANCH_COLOURS = BRANCH_COLOURS;
  const MIN_SCALE = 0.4, MAX_SCALE = 2;
  A.MAX_SCALE = MAX_SCALE;
  A.MIN_SCALE = MIN_SCALE;
  const PANEL_MIN = 240, PANEL_MAX = 600, PANEL_DEFAULT = 320;
  A.PANEL_DEFAULT = PANEL_DEFAULT;
  A.PANEL_MAX = PANEL_MAX;
  A.PANEL_MIN = PANEL_MIN;
  const MAX_TITLE = 120;
  A.MAX_TITLE = MAX_TITLE;
  const AI_ACTIONS = [
    { act: "describe", label: "Expand description", icon: "text", hint: "The AI rewrites and extends this node\u2019s description" },
    { act: "develop", label: "Expand topic", icon: "fork", hint: "The AI adds child nodes under this node" },
    { act: "correct", label: "Correct", icon: "edit", hint: "Say what is wrong; the AI fixes this node" },
    { act: "investigate", label: "Research", icon: "search", hint: "The AI looks for facts about this node in the project and on the web" }
  ];
  A.AI_ACTIONS = AI_ACTIONS;
  const ICONS = {
    plus: "M12 5v14M5 12h14",
    minus: "M5 12h14",
    sparkle: "M12 3l2.2 6.8L21 12l-6.8 2.2L12 21l-2.2-6.8L3 12l6.8-2.2z",
    link: "M3 12h18M7 8l-4 4 4 4M17 8l4 4-4 4",
    edit: "M4 20l1-4L16 5l3 3L8 19zM14 7l3 3",
    text: "M4 6h16M4 11h16M4 16h10",
    fork: "M4 12h7M11 5v14M11 5h9M11 12h9M11 19h9",
    chevron: "M6 9l6 6 6-6",
    download: "M12 4v11M7 11l5 5 5-5M5 20h14",
    grid: "M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h6v6h-6z",
    trash: "M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13M10 11v6M14 11v6",
    source: "M8 7l-5 5 5 5M16 7l5 5-5 5M14 5l-4 14",
    centre: "M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8zM12 2v3M12 19v3M2 12h3M19 12h3",
    search: "M10 4a6 6 0 1 0 0 12 6 6 0 0 0 0-12zM15 15l5 5",
    stop: "M7 7h10v10H7z",
    play: "M8 5l11 7-11 7z",
    close: "M6 6l12 12M18 6L6 18",
    open: "M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5",
    diagram: "M4 4h7v5H4zM13 15h7v5h-7zM7.5 9v3.5h9V15",
    photo: "M4 5h16v14H4zM4 16l5-5 4 4 3-3 4 4M9 9a.8.8 0 1 0 0 .01"
  };
  const NODE_ICONS = {
    check: "M5 12l5 5L20 7",
    warning: "M12 4l9 16H3zM12 10v4M12 17v.5",
    error: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM9 9l6 6M15 9l-6 6",
    info: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 11v6M12 7.5v.5",
    question: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.7.4-1 .9-1 1.7M12 17v.5",
    bug: "M9 7a3 3 0 0 1 6 0M8 9h8v5a4 4 0 0 1-8 0zM4 10l4 1M20 10l-4 1M4 17l4-2M20 17l-4-2M12 9v9",
    lock: "M7 11V8a5 5 0 0 1 10 0v3M5 11h14v9H5zM12 15v2",
    key: "M8 11a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7zM10.5 13.5L20 4M16 8l3 3M13 11l2 2",
    database: "M4 6c0-1.7 3.6-3 8-3s8 1.3 8 3-3.6 3-8 3-8-1.3-8-3zM4 6v12c0 1.7 3.6 3 8 3s8-1.3 8-3V6M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3",
    server: "M4 4h16v6H4zM4 14h16v6H4zM8 7h.5M8 17h.5",
    cloud: "M7 18a4 4 0 0 1-.5-8A6 6 0 0 1 18 9a4.5 4.5 0 0 1 0 9z",
    user: "M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21a8 8 0 0 1 16 0",
    users: "M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM2 20a7 7 0 0 1 14 0M16 5a3.5 3.5 0 0 1 0 6M18 14a6 6 0 0 1 4 6",
    clock: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 7v5l3 2",
    calendar: "M4 6h16v14H4zM4 10h16M8 3v4M16 3v4",
    flag: "M5 21V4M5 4h11l-2 4 2 4H5",
    star: "M12 3l2.8 5.7 6.2.9-4.5 4.4 1 6.2L12 17.3 6.5 20.2l1-6.2L3 9.6l6.2-.9z",
    heart: "M12 20s-8-5-8-11a4.5 4.5 0 0 1 8-2.5A4.5 4.5 0 0 1 20 9c0 6-8 11-8 11z",
    bulb: "M9 18h6M10 21h4M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2.1h5c0-.9.4-1.6 1-2.1A6 6 0 0 0 12 3z",
    target: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8zM12 12v.01",
    rocket: "M12 2c3 2.5 4.5 6 4.5 10v3h-9v-3C7.5 8 9 4.5 12 2zM12 8.5a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3zM7.5 13L5 16v3l3-1.5M16.5 13l2.5 3v3l-3-1.5M10.5 18v3M13.5 18v3",
    book: "M4 5a2 2 0 0 1 2-2h13v16H6a2 2 0 0 0-2 2zM4 19a2 2 0 0 1 2-2h13",
    file: "M6 3h8l4 4v14H6zM14 3v4h4M9 12h6M9 16h6",
    folder: "M3 6a1 1 0 0 1 1-1h5l2 2h8a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1z",
    code: "M8 7l-5 5 5 5M16 7l5 5-5 5M14 4l-4 16",
    terminal: "M4 5h16v14H4zM7 9l3 3-3 3M12 15h5",
    gear: "M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M18.4 5.6l-2.1 2.1M7.7 16.3l-2.1 2.1",
    shield: "M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z",
    globe: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18",
    chain: "M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1",
    mail: "M3 5h18v14H3zM3 7l9 7 9-7",
    chat: "M4 5h16v11H9l-5 4z",
    money: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM14.5 9.5c-.5-1-1.5-1.5-2.5-1.5-1.4 0-2.5.8-2.5 2s1 1.7 2.5 2 2.5.8 2.5 2-1.1 2-2.5 2c-1 0-2-.5-2.5-1.5M12 6.5V8M12 16v1.5",
    chart: "M4 20h16M7 17v-6M12 17V6M17 17v-9",
    trend: "M3 17l6-6 4 4 8-8M15 7h6v6",
    bolt: "M13 3L5 14h6l-1 7 8-11h-6z",
    pin: "M12 21v-6M8 4h8l-1 6 3 3H6l3-3z",
    tag: "M3 12V4h8l10 10-8 8zM7.5 8.5v.01",
    bell: "M6 16v-5a6 6 0 0 1 12 0v5l2 2H4zM10 21h4",
    eye: "M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12zM12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z",
    package: "M12 3l8 4v10l-8 4-8-4V7zM4 7l8 4 8-4M12 11v10"
  };
  A.NODE_ICONS = NODE_ICONS;
  const NODE_ICON_IDS = Object.keys(NODE_ICONS);
  A.NODE_ICON_IDS = NODE_ICON_IDS;
  const MAX_NUMBER = 999;
  A.MAX_NUMBER = MAX_NUMBER;
  const SHAPE_IDS = ["rounded", "rectangle", "pill", "ellipse", "diamond"];
  A.SHAPE_IDS = SHAPE_IDS;
  const SHAPE_PATHS = {
    rounded: "M6 7h12a3 3 0 0 1 3 3v4a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3v-4a3 3 0 0 1 3-3z",
    rectangle: "M3 7h18v10H3z",
    pill: "M9 7h6a5 5 0 0 1 0 10H9A5 5 0 0 1 9 7z",
    ellipse: "M3 12a9 6 0 1 0 18 0 9 6 0 1 0-18 0z",
    diamond: "M12 4l9 8-9 8-9-8z"
  };
  A.SHAPE_PATHS = SHAPE_PATHS;
  const SHAPE_NAMES = { rounded: "Rounded", rectangle: "Rectangle", pill: "Pill", ellipse: "Ellipse", diamond: "Diamond" };
  A.SHAPE_NAMES = SHAPE_NAMES;
  const LIMITS = { width: [60, 800], height: [28, 600] };
  A.LIMITS = LIMITS;
  const SIZE_PRESETS = [{ id: "s", label: "S", w: 140, h: 44 }, { id: "m", label: "M", w: 220, h: 64 }, { id: "l", label: "L", w: 320, h: 96 }];
  A.SIZE_PRESETS = SIZE_PRESETS;
  const SHAPE_FIT = {
    ellipse: { k: Math.SQRT1_2, padX: 12, padY: 7, maxText: 170, minW: 88, minH: 46 },
    diamond: { k: 0.5, padX: 8, padY: 5, maxText: 130, minW: 112, minH: 68 }
  };
  A.SHAPE_FIT = SHAPE_FIT;
  const HANDLES = ["nw", "n", "ne", "e", "se", "s", "sw", "w"];
  A.HANDLES = HANDLES;
  function append(parent, child) {
    if (child == null || child === false) return;
    if (Array.isArray(child)) {
      child.forEach(function(c) {
        append(parent, c);
      });
      return;
    }
    parent.appendChild(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  function h(tag, attrs) {
    const node = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function(key) {
        const value = attrs[key];
        if (value == null || value === false) return;
        if (key === "class") node.className = value;
        else if (key === "text") node.textContent = value;
        else if (key.indexOf("on") === 0 && typeof value === "function") node.addEventListener(key.slice(2).toLowerCase(), value);
        else if (key === "value" || key === "disabled" || key === "hidden") node[key] = value;
        else node.setAttribute(key, value === true ? "" : value);
      });
    }
    for (let i = 2; i < arguments.length; i++) append(node, arguments[i]);
    return node;
  }
  function icon(name, table) {
    const svg = document.createElementNS(NS, "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("fill", "none");
    svg.setAttribute("stroke", "currentColor");
    svg.setAttribute("stroke-width", "2");
    svg.setAttribute("stroke-linecap", "round");
    svg.setAttribute("stroke-linejoin", "round");
    svg.setAttribute("aria-hidden", "true");
    const path = document.createElementNS(NS, "path");
    path.setAttribute("d", (table || ICONS)[name] || "");
    svg.appendChild(path);
    return svg;
  }
  function clamp(value, low, high) {
    return Math.max(low, Math.min(high, value));
  }
  function now() {
    return typeof performance !== "undefined" && performance.now ? performance.now() : Date.now();
  }
  const CARD_BOX = { w: 280, h: 190 }, PANEL_BOX = { w: 460, h: 300 };
  A.PANEL_BOX = PANEL_BOX;
  A.CARD_BOX = CARD_BOX;
  const VISUAL_KINDS = [["text", "Text"], ["diagram", "Diagram"], ["image", "Image"]];
  A.VISUAL_KINDS = VISUAL_KINDS;
  const vis = { cache: /* @__PURE__ */ new Map(), queue: Promise.resolve(), counter: 0 };
  function fenceOf(text) {
    const lines = String(text || "").split("\n");
    for (let i = 0; i < lines.length; i++) {
      const t = lines[i].trim();
      if (t.indexOf("```") !== 0 || t.slice(3).trim().toLowerCase() !== "mermaid") continue;
      for (let j = i + 1; j < lines.length; j++) {
        if (lines[j].trim().indexOf("```") === 0) return { from: i, to: j, lines, source: lines.slice(i + 1, j).join("\n").trim() };
      }
      return null;
    }
    return null;
  }
  function diagramSourceOf(text) {
    const f = fenceOf(text);
    return f && f.source ? f.source : null;
  }
  function imageOf(text) {
    const s = String(text || "");
    const open = s.indexOf("![");
    if (open < 0) return null;
    const mid = s.indexOf("](", open + 2);
    if (mid < 0) return null;
    const close = s.indexOf(")", mid + 2);
    if (close < 0) return null;
    const alt = s.slice(open + 2, mid);
    let src = s.slice(mid + 2, close).trim();
    const space = src.indexOf(" ");
    if (space >= 0) src = src.slice(0, space);
    if (alt.indexOf("\n") >= 0 || !src) return null;
    return { alt, src, from: open, to: close + 1 };
  }
  function withDiagram(text, source) {
    const body = String(source || "").split("\n").filter(function(line) {
      return line.trim().indexOf("```") !== 0;
    }).join("\n").replace(/\s+$/, "");
    const fence = body ? ["```mermaid"].concat(body.split("\n"), ["```"]) : [];
    const f = fenceOf(text);
    if (f) {
      const lines = f.lines.slice();
      lines.splice.apply(lines, [f.from, f.to - f.from + 1].concat(fence));
      return lines.join("\n");
    }
    if (!fence.length) return String(text || "");
    return fence.join("\n") + (String(text || "").trim() ? "\n\n" + text : "");
  }
  function withImage(text, alt, src) {
    const s = String(text || "");
    const address = String(src || "").trim().replace(/ /g, "%20").replace(/\)/g, "%29");
    const markdown = address ? "![" + String(alt || "").replace(/[\[\]\n]/g, " ").trim() + "](" + address + ")" : "";
    const found = imageOf(s);
    if (found) return s.slice(0, found.from) + markdown + s.slice(found.to);
    if (!markdown) return s;
    return markdown + (s.trim() ? "\n\n" + s : "");
  }
  function visualOf(node) {
    if (!node || !node.visual) return null;
    if (node.visual === "diagram") {
      const source = diagramSourceOf(node.description);
      return source ? { kind: "diagram", source } : null;
    }
    if (node.visual === "image") {
      const image = imageOf(node.description);
      return image ? { kind: "image", alt: image.alt, src: image.src } : null;
    }
    return null;
  }
  function imageURL(src) {
    const written = String(src || "").trim();
    if (!written) return null;
    if (/^(https?:|data:image\/)/i.test(written)) return written;
    if (/^[a-z][a-z0-9+.-]*:/i.test(written)) return null;
    const base = typeof state !== "undefined" ? state.documentBaseURL : null;
    return window.MarkViewDocumentFiles && base && window.MarkViewDocumentFiles.pictureURL(written, base) || null;
  }
  function drawDiagram(key, source, forcedTheme) {
    if (vis.cache.has(key)) return Promise.resolve(vis.cache.get(key));
    const remember = function(result) {
      vis.cache.set(key, result);
      if (vis.cache.size > 80) vis.cache.delete(vis.cache.keys().next().value);
      return result;
    };
    const run = function() {
      if (typeof mermaid === "undefined") return remember({ error: "Mermaid is not available." });
      const id = "rmv" + ++vis.counter;
      try {
        mermaid.initialize(Object.assign({ startOnLoad: false, securityLevel: "strict" }, forcedTheme ? { theme: forcedTheme } : MarkViewThemes.mermaid()));
      } catch (e) {
      }
      return Promise.resolve().then(function() {
        return mermaid.render(id, source);
      }).then(function(drawn) {
        const doc = new DOMParser().parseFromString(drawn.svg, "image/svg+xml").documentElement;
        const box = (doc.getAttribute("viewBox") || "").trim().split(/[\s,]+/).map(Number);
        const w = box.length === 4 && box[2] > 0 ? box[2] : 300, hgt = box.length === 4 && box[3] > 0 ? box[3] : 150;
        return remember({ svg: drawn.svg, w, h: hgt });
      }).catch(function(error) {
        const junk = document.getElementById("d" + id);
        if (junk) junk.remove();
        return remember({ error: String(error && error.message || error || "The diagram could not be drawn.").slice(0, 300) });
      });
    };
    const next = vis.queue.then(run, run);
    vis.queue = next.then(function() {
    }, function() {
    });
    return next;
  }
  function placeDiagram(box, result, limits) {
    box.textContent = "";
    box.classList.toggle("error", !!result.error);
    if (result.error) {
      box.appendChild(h("span", { class: "rm-vis-note", title: result.error }, "This diagram could not be drawn"));
      return;
    }
    const holder = document.createElement("span");
    holder.innerHTML = window.mvKit.sanitizeMermaidSvg(result.svg);
    const svg = holder.querySelector("svg");
    if (!svg) return;
    const k = Math.min(1, limits.w / result.w, limits.h / result.h);
    svg.setAttribute("width", String(Math.max(40, Math.round(result.w * k))));
    svg.setAttribute("height", String(Math.max(24, Math.round(result.h * k))));
    svg.style.maxWidth = "100%";
    svg.style.height = "auto";
    box.appendChild(svg);
  }
  function fillVisual(box, v, limits, label, done) {
    const key = v.kind + "\n" + (v.kind === "diagram" ? v.source : v.src) + "\n" + MarkViewThemes.signature();
    if (box._vk === key) return;
    box._vk = key;
    box.setAttribute("role", "img");
    box.setAttribute("aria-label", label);
    box.classList.remove("error");
    if (v.kind === "diagram") {
      if (vis.cache.has(key)) {
        placeDiagram(box, vis.cache.get(key), limits);
        return;
      }
      box.textContent = "";
      box.appendChild(h("span", { class: "rm-vis-note" }, "Drawing\u2026"));
      drawDiagram(key, v.source).then(function(result) {
        if (box._vk !== key) return;
        placeDiagram(box, result, limits);
        if (done) done();
      });
      return;
    }
    const url = imageURL(v.src);
    box.textContent = "";
    if (!url) {
      box.classList.add("error");
      box.appendChild(h("span", { class: "rm-vis-note" }, "This image address is not supported"));
      return;
    }
    const img = h("img", { alt: v.alt || label, draggable: "false" });
    img.style.maxWidth = limits.w + "px";
    img.style.maxHeight = limits.h + "px";
    img.addEventListener("load", function() {
      if (box._vk === key && done) done();
    });
    img.addEventListener("error", function() {
      if (box._vk !== key) return;
      box.classList.add("error");
      box.textContent = "";
      box.appendChild(h("span", { class: "rm-vis-note", title: v.src }, "This image could not be loaded"));
      if (done) done();
    });
    box.appendChild(img);
    img.src = url;
  }
  function reportError(where, error) {
    try {
      if (typeof sendToSwift === "function") sendToSwift("jsError", { where: "research-map " + where, message: String(error && error.message || error), source: "markview-research-map-core.js", lineno: 0, colno: 0, stack: String(error && error.stack || "") });
    } catch (_) {
    }
  }
  function isResearchMapText(text) {
    if (typeof text !== "string") return false;
    const match = /^﻿?---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(text);
    return !!match && /^type[ \t]*:[ \t]*["']?research-map["']?[ \t]*(?:#.*)?$/m.test(match[1]);
  }
  function hexToRgb(hex) {
    const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex || "");
    return m ? [parseInt(m[1], 16), parseInt(m[2], 16), parseInt(m[3], 16)] : null;
  }
  function mix(hex, base, amount) {
    const a = hexToRgb(hex), b = hexToRgb(base);
    if (!a || !b) return base;
    const c = a.map(function(v, i) {
      return Math.round(v * amount + b[i] * (1 - amount));
    });
    return "#" + c.map(function(v) {
      return v.toString(16).padStart(2, "0");
    }).join("");
  }
  function readableOn(hex) {
    const r = parseInt(hex.slice(1, 3), 16), g = parseInt(hex.slice(3, 5), 16), b = parseInt(hex.slice(5, 7), 16);
    return 0.299 * r + 0.587 * g + 0.114 * b > 150 ? "#1e1e1e" : "#ffffff";
  }
  function setGlyph(glyph, value) {
    if (glyph.getAttribute("data-icon") === value) return;
    glyph.setAttribute("data-icon", value);
    glyph.textContent = "";
    glyph.hidden = !value;
    if (!value) return;
    if (NODE_ICONS[value]) glyph.appendChild(icon(value, NODE_ICONS));
    else glyph.appendChild(document.createTextNode(value));
  }
  function setThumb(entry, id, address) {
    const url = address ? imageURL(address) : null;
    const key = url || "";
    if (entry.thumb._key === key) return;
    entry.thumb._key = key;
    if (!url) {
      entry.thumb.hidden = true;
      entry.thumb.removeAttribute("src");
      return;
    }
    entry.thumb.hidden = false;
    entry.thumb.onload = function() {
      A.remeasure(id);
    };
    entry.thumb.onerror = function() {
      entry.thumb.hidden = true;
      const node = A.nodeById(id);
      entry.lead.hidden = !node || node.number == null && !node.icon;
      A.remeasure(id);
    };
    entry.thumb.src = url;
  }
  const rm = {
    active: false,
    docId: null,
    snap: null,
    mapKey: "",
    sourceBase: null,
    // the Source text as of the last sync with Swift (see applySnapshot)
    selected: null,
    // null until the first snapshot picks one; '' is "nothing selected"
    fallbackSelect: "",
    // what to select when the selected node disappears (the parent of a deleted node)
    view: { x: 0, y: 0, scale: 1 },
    viewReady: false,
    panelWidth: PANEL_DEFAULT,
    positions: {},
    sizes: {},
    moves: {},
    // moves not yet confirmed by a snapshot: id -> {x, y, sent}
    moveQueue: {},
    // keyboard moves waiting to be sent: id -> {doc, x, y, timer}
    drag: null,
    // {id, x, y} while a node is being dragged
    resize: null,
    // {id, width, height} while a node is being resized with its handles (null is automatic)
    boxes: {},
    // sizes sent and not yet confirmed by a snapshot: id -> {width, height}
    pending: {},
    // property edits waiting to be sent: id -> {doc, fields, timer}
    els: /* @__PURE__ */ new Map(),
    collapsed: /* @__PURE__ */ new Set(),
    // ids of nodes whose children are folded away (view state, DEC-010)
    selLink: "",
    // "from|to" of the selected logical connection (REQ-015), '' for none
    connect: null,
    // {from, x, y, target} while an arrow is dragged (REQ-015)
    panelFor: null,
    menu: null,
    menuEl: null,
    exportOpen: false,
    dialog: null,
    lastDragEnd: 0,
    saveTimer: 0,
    toastTimer: 0,
    ticker: 0,
    queriesOpen: false
  };
  A.rm = rm;
  function sendAs(doc, action, fields) {
    if (typeof sendToSwift !== "function") return;
    const payload = Object.assign({ action }, fields || {});
    const current = window.mvDocumentId;
    if (doc !== void 0 && doc !== (current || "")) {
      window.mvDocumentId = doc;
      try {
        sendToSwift("researchMap", payload);
      } finally {
        window.mvDocumentId = current;
      }
    } else sendToSwift("researchMap", payload);
  }
  function send(action, fields) {
    sendAs(void 0, action, fields);
  }
  function queueUpdate(id, patch, immediately) {
    let entry = rm.pending[id];
    if (!entry) entry = rm.pending[id] = { doc: window.mvDocumentId || "", fields: {}, timer: 0 };
    Object.assign(entry.fields, patch);
    clearTimeout(entry.timer);
    if (immediately) flushUpdate(id);
    else entry.timer = setTimeout(function() {
      flushUpdate(id);
    }, 300);
  }
  function flushUpdate(id) {
    const entry = rm.pending[id];
    if (!entry) return;
    clearTimeout(entry.timer);
    delete rm.pending[id];
    if (Object.keys(entry.fields).length) sendAs(entry.doc, "update", Object.assign({ id }, entry.fields));
  }
  function queueMove(id, x, y) {
    let entry = rm.moveQueue[id];
    if (!entry) entry = rm.moveQueue[id] = { doc: window.mvDocumentId || "", x, y, timer: 0 };
    entry.x = x;
    entry.y = y;
    clearTimeout(entry.timer);
    entry.timer = setTimeout(function() {
      flushMove(id);
    }, 250);
  }
  function flushMove(id) {
    const entry = rm.moveQueue[id];
    if (!entry) return;
    clearTimeout(entry.timer);
    delete rm.moveQueue[id];
    if (rm.moves[id]) rm.moves[id].sent = true;
    sendAs(entry.doc, "moveVisual", { id, x: entry.x, y: entry.y });
  }
  function flushAll() {
    Object.keys(rm.pending).forEach(flushUpdate);
    Object.keys(rm.moveQueue).forEach(flushMove);
  }
  function loadSaved() {
    try {
      const raw = localStorage.getItem(rm.mapKey);
      return raw ? JSON.parse(raw) : null;
    } catch (e) {
      return null;
    }
  }
  function saveNow() {
    if (!rm.mapKey) return;
    try {
      localStorage.setItem(rm.mapKey, JSON.stringify({ x: rm.view.x, y: rm.view.y, scale: rm.view.scale, panel: rm.panelWidth, selected: rm.selected == null ? "" : rm.selected, collapsed: Array.from(rm.collapsed) }));
    } catch (e) {
    }
  }
  function saveSoon() {
    clearTimeout(rm.saveTimer);
    rm.saveTimer = setTimeout(saveNow, 120);
  }
})(window.MVResearchMapView = {});
;
(function(A) {
  "use strict";
  if (!A.ready) return;
  const {
    AI_ACTIONS,
    LIMITS,
    MAX_NUMBER,
    MAX_TITLE,
    NS,
    PANEL_DEFAULT,
    PANEL_MAX,
    PANEL_MIN,
    SHAPE_IDS,
    SHAPE_PATHS,
    SIZE_PRESETS,
    VISUAL_KINDS,
    flushUpdate,
    h,
    host,
    icon,
    imageOf,
    queueUpdate,
    rm,
    withDiagram,
    withImage
  } = A;
  Object.assign(A, { fitTitle, modeSwitch });
  const css = `
    .rm-root { display: none; flex: 1; min-width: 0; min-height: 0; flex-direction: column; position: relative; overflow: hidden; background: var(--rm-page); color: var(--rm-ink); font-family: var(--font-sans); font-size: calc(12px * var(--ui-scale, 1)); line-height: 1.5;
        --rm-page: var(--bg-primary); --rm-bar: var(--bg-secondary); --rm-line: var(--border-color); --rm-ink: var(--text-primary); --rm-muted: var(--text-secondary);
        --rm-dots: var(--cv-grid-dot, rgba(255, 255, 255, 0.055)); --rm-chip: var(--bg-tertiary); --rm-field: var(--bg-primary);
        --rm-hover: var(--toolbar-hover-bg); --rm-icon-fg: var(--toolbar-text); --rm-active: var(--rm-active-bg); --rm-primary: var(--rm-primary-bg); --rm-primary-hover: var(--rm-primary-hover-bg); --rm-danger: var(--rm-danger-bg); --rm-focus: var(--accent-primary);
        --rm-warn-bg: rgba(206, 145, 120, 0.16); --rm-warn-fg: var(--accent-warning); --rm-error: var(--accent-danger); --rm-pop: var(--shadow-lg); --rm-badge-ink: #1e1e1e;
        --b0: #569cd6; --b1: #4ec9b0; --b2: #c586c0; --b3: #dcdcaa; --b4: #ce9178; --b5: #9cdcfe; }
    html[data-theme="light"] .rm-root {
        --rm-warn-bg: rgba(176, 136, 0, 0.14); --rm-pop: 0 4px 14px rgba(0, 0, 0, 0.18); --rm-badge-ink: #ffffff;
        --b0: #0366d6; --b1: #22863a; --b2: #8250df; --b3: #9a6700; --b4: #cf4a1a; --b5: #0a7ea4; }
    .rm-root.visible { display: flex; }
    .rm-root [hidden] { display: none !important; }
    .rm-root button { font: inherit; }
    .rm-toolbar { position: relative; display: flex; align-items: center; gap: 4px; padding: 3px 8px; min-height: calc(32px * var(--ui-scale, 1)); background: var(--rm-bar); border-bottom: 1px solid var(--rm-line); flex: none; }
    .rm-tool { position: relative; display: inline-grid; place-items: center; flex: none; width: calc(26px * var(--ui-scale, 1)); height: calc(26px * var(--ui-scale, 1)); padding: 0; border: 0; border-radius: 3px; background: transparent; color: var(--rm-icon-fg); cursor: pointer; transition: background .15s, color .15s; }
    .rm-tool:hover:not(:disabled) { background: var(--rm-hover); color: var(--rm-ink); }
    .rm-tool svg { width: 15px; height: 15px; }
    .rm-tool .rm-count { position: absolute; top: -3px; right: -3px; min-width: 14px; height: 14px; padding: 0 3px; border-radius: 7px; background: var(--rm-primary); color: var(--on-rm-primary); font-size: 9px; line-height: 14px; text-align: center; }
    .rm-tbtn { flex: none; display: inline-flex; align-items: center; gap: 4px; height: calc(24px * var(--ui-scale, 1)); padding: 0 8px; border: 1px solid transparent; border-radius: 3px; background: transparent; color: var(--rm-icon-fg); font-size: calc(11px * var(--ui-scale, 1)); white-space: nowrap; cursor: pointer; transition: background .15s, color .15s; }
    .rm-tbtn:hover:not(:disabled) { background: var(--rm-hover); color: var(--rm-ink); }
    .rm-tbtn[aria-expanded="true"] { background: var(--rm-hover); color: var(--rm-ink); }
    .rm-tbtn svg { width: 12px; height: 12px; }
    .rm-tsep { flex: none; width: 1px; height: 14px; margin: 0 3px; background: var(--rm-line); }
    /* The Map | View | Source switch (REQ-010) sits in the map toolbar and in the top bar, so it uses the application's tokens only. */
    .mv-modes { display: inline-flex; flex: none; overflow: hidden; border: 1px solid var(--border-color); border-radius: 4px; background: var(--bg-primary); }
    .mv-modes[hidden] { display: none; }
    .mv-modes.mv-modes button { height: calc(22px * var(--ui-scale, 1)); width: auto; min-width: 0; padding: 0 10px; border: 0; border-left: 1px solid var(--border-color); border-radius: 0; background: transparent; color: var(--text-secondary); font: inherit; font-size: calc(11px * var(--ui-scale, 1)); cursor: pointer; }
    .mv-modes.mv-modes button:first-child { border-left: 0; }
    .mv-modes.mv-modes button:hover { background: var(--bg-tertiary); color: var(--text-primary); }
    .mv-modes.mv-modes button[aria-pressed="true"] { background: var(--accent-fill); color: var(--on-accent); }
    .mv-modes.mv-modes button:focus-visible { outline: 2px solid var(--accent-primary); outline-offset: -2px; }
    .wysiwyg-toolbar > .mv-modes { margin-right: 6px; }
    /* The View of a map is read only: the formatting buttons (all call fmt*) have nothing to act on. */
    body.rm-view-readonly .wysiwyg-toolbar > button[onclick^="fmt"], body.rm-view-readonly .wysiwyg-toolbar > .sep { display: none; }
    .rm-heading { display: flex; flex-direction: column; flex: 1; min-width: 0; margin-left: 4px; line-height: 1.25; }
    .rm-heading strong { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 1.05em; font-weight: 600; }
    .rm-heading span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--rm-muted); font-size: .9em; }
    .rm-heading span:empty { display: none; }
    .rm-zoom { min-width: 3.2em; text-align: center; color: var(--rm-muted); font-variant-numeric: tabular-nums; }
    .rm-status { display: inline-flex; align-items: center; gap: 8px; min-width: 0; max-width: 40%; padding: 2px 3px 2px 10px; border: 1px solid var(--rm-line); border-radius: 999px; background: var(--rm-chip); font-size: .95em; }
    .rm-status.warn { border-color: transparent; background: var(--rm-warn-bg); color: var(--rm-warn-fg); }
    .rm-status[hidden] { display: none; }
    .rm-status-text { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .rm-elapsed { color: var(--rm-muted); font-variant-numeric: tabular-nums; }
    .rm-spin { flex: none; width: 11px; height: 11px; border: 2px solid var(--accent-primary); border-right-color: transparent; border-radius: 50%; animation: rm-spin .9s linear infinite; }
    @keyframes rm-spin { to { transform: rotate(360deg); } }
    .rm-chip-btn { flex: none; display: inline-flex; align-items: center; gap: 4px; padding: 1px 9px; border: 0; border-radius: 999px; background: transparent; color: var(--rm-ink); cursor: pointer; }
    .rm-chip-btn:hover { background: var(--rm-hover); }
    .rm-chip-btn svg { width: 10px; height: 10px; }
    .rm-popover { position: absolute; z-index: 20; top: calc(100% + 4px); right: 8px; width: min(420px, 80%); max-height: 50vh; overflow: auto; padding: 8px 12px; border: 1px solid var(--rm-line); border-radius: 6px; background: var(--rm-bar); box-shadow: var(--rm-pop); }
    .rm-popover h3 { margin: 0 0 4px; font-size: .9em; color: var(--rm-muted); font-weight: 600; }
    .rm-popover ol { margin: 0; padding-left: 20px; }
    .rm-popover li { margin: 3px 0; overflow-wrap: anywhere; }
    .rm-exportmenu { position: absolute; z-index: 20; top: calc(100% + 2px); right: 8px; display: flex; flex-direction: column; min-width: 190px; padding: 4px; border: 1px solid var(--rm-line); border-radius: 6px; background: var(--rm-bar); box-shadow: var(--rm-pop); }
    .rm-workspace { display: flex; flex: 1; min-height: 0; --rm-panel-width: ${PANEL_DEFAULT}px; }
    .rm-left { position: relative; display: flex; flex: 1; min-width: 0; flex-direction: column; }
    .rm-viewport { position: relative; flex: 1; overflow: hidden; touch-action: none; cursor: grab; background-color: var(--rm-page); background-image: radial-gradient(var(--rm-dots) 1px, transparent 1px); background-size: 24px 24px; outline: none; }
    .rm-viewport.is-panning { cursor: grabbing; }
    .rm-world { position: absolute; left: 0; top: 0; width: 1px; height: 1px; transform-origin: 0 0; }
    .rm-lines { position: absolute; left: 0; top: 0; overflow: visible; pointer-events: none; }
    .rm-loading { position: absolute; inset: 0; display: grid; place-items: center; color: var(--rm-muted); pointer-events: none; }
    .rm-loading:empty { display: none; }
    .rm-hint { position: absolute; left: 10px; bottom: 8px; padding: 3px 8px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-bar); color: var(--rm-muted); font-size: .92em; pointer-events: none; }
    .rm-readout { position: absolute; right: 10px; bottom: 8px; padding: 3px 8px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-bar); color: var(--rm-muted); font-size: .92em; font-variant-numeric: tabular-nums; pointer-events: none; }
    .rm-readout[hidden] { display: none; }
    .rm-node-wrap { position: absolute; transform: translate(-50%, -50%); z-index: 1; width: max-content; max-width: 220px; }
    .rm-node-wrap.menu-open { z-index: 4; }
    .rm-node { position: relative; display: block; min-width: 96px; max-width: 220px; margin: 0; padding: 7px 26px 7px 11px; border: 1px solid var(--rm-line); border-left: 3px solid var(--branch, var(--b0)); border-radius: 6px; background: var(--rm-bar); color: var(--rm-ink);
        box-shadow: var(--shadow-sm); text-align: left; white-space: normal; overflow-wrap: anywhere; line-height: 1.35; font-size: calc(12px * var(--ui-scale, 1)); font-weight: 500; cursor: grab; touch-action: none; -webkit-user-select: none; user-select: none; }
    .rm-node:active { cursor: grabbing; }
    .rm-node.root { min-width: 150px; padding: 10px 26px 10px 13px; border-radius: 8px; background: var(--rm-chip); font-size: calc(14px * var(--ui-scale, 1)); font-weight: 600; box-shadow: var(--shadow-md); }
    .rm-lead { display: inline-flex; align-items: center; gap: 4px; margin-right: 6px; vertical-align: middle; }
    .rm-lead[hidden], .rm-badge[hidden], .rm-glyph[hidden] { display: none; }
    .rm-badge { display: inline-grid; place-items: center; min-width: 1.5em; height: 1.5em; padding: 0 .4em; border-radius: .75em; background: var(--branch, var(--b0)); color: var(--badge-ink, var(--rm-badge-ink)); font-size: .85em; font-weight: 700; font-variant-numeric: tabular-nums; line-height: 1; }
    .rm-glyph { display: inline-grid; place-items: center; width: 1.25em; height: 1.25em; color: var(--branch, var(--b0)); font-size: 1.05em; line-height: 1; }
    .rm-glyph svg { width: 100%; height: 100%; }
    /* The picture of a node (REQ-017): small, beside the icon, before the title. */
    .rm-thumb { display: block; width: 30px; height: 30px; object-fit: cover; border-radius: 5px; border: 1px solid var(--rm-line); background: var(--rm-page); }
    .rm-thumb[hidden] { display: none; }
    .rm-body { position: relative; z-index: 1; display: block; min-width: 0; }
    /* A given width: the wrap is exactly that wide and the title wraps in it. A given height or a shape: the card is a column that centres its title. */
    .rm-node-wrap.has-w { max-width: none; }
    .rm-node-wrap.has-w .rm-node { width: 100%; min-width: 0; max-width: none; }
    .rm-node.boxed { display: flex; flex-direction: column; justify-content: center; }
    .rm-node-wrap.visual { max-width: 320px; }
    .rm-node.is-visual, .rm-node.root.is-visual { min-width: 150px; max-width: 320px; padding: 6px 26px 6px 8px; }
    .rm-node.is-visual .rm-lead, .rm-node.is-visual .rm-label { display: none; }
    .rm-vis { display: block; line-height: 0; }
    .rm-vis[hidden] { display: none; }
    .rm-vis svg, .rm-vis img { display: block; max-width: 100%; }
    .rm-vis svg { height: auto; }
    .rm-vis-note { display: block; padding: 6px 4px; line-height: 1.4; font-size: .85em; color: var(--rm-muted); }
    .rm-vis.error .rm-vis-note { color: var(--rm-error); }
    /* Shapes (REQ-009, DEC-012). The rounded rectangle is the default look and has no class; the rectangle keeps the branch stripe. */
    .rm-node-wrap.shape-rectangle .rm-node { border-radius: 0; }
    .rm-node-wrap.shape-pill .rm-node, .rm-node-wrap.shape-ellipse .rm-node { border: 1.5px solid var(--branch, var(--b0)); }
    .rm-node-wrap.shape-pill .rm-node { border-radius: 999px; padding: 7px 30px 7px 18px; }
    .rm-node-wrap.shape-pill .rm-node.root { padding: 10px 32px 10px 22px; }
    .rm-node-wrap.shape-ellipse .rm-node { border-radius: 50%; align-items: center; padding: 0 6px; text-align: center; }
    .rm-node-wrap.shape-diamond .rm-node { align-items: center; padding: 0 6px; border: 0; background: transparent !important; box-shadow: none !important; text-align: center; }
    .rm-node-wrap.shape-pill .rm-node[aria-pressed="true"], .rm-node-wrap.shape-ellipse .rm-node[aria-pressed="true"] { border-color: var(--accent-primary); }
    .rm-shape { position: absolute; left: 0; top: 0; width: 100%; height: 100%; overflow: visible; pointer-events: none; filter: drop-shadow(0 1px 2px rgba(0, 0, 0, .35)); }
    .rm-shape polygon { fill: var(--rm-bar); stroke: var(--branch, var(--b0)); stroke-width: 2; stroke-linejoin: round; vector-effect: non-scaling-stroke; }
    .rm-node.root .rm-shape polygon { fill: var(--rm-chip); }
    .rm-node.has-color .rm-shape polygon { fill: var(--tint-dark); }
    html[data-theme="light"] .rm-node.has-color .rm-shape polygon { fill: var(--tint); }
    .rm-node[aria-pressed="true"] .rm-shape polygon { stroke: var(--accent-primary); stroke-width: 3; }
    .rm-node-wrap.shape-pill .rm-tri { top: 50%; right: 8px; transform: translateY(-50%); }
    .rm-node-wrap.shape-ellipse .rm-tri { top: 11%; right: 13%; }
    .rm-node-wrap.shape-diamond .rm-tri { top: calc(25% - 9px); right: calc(25% - 10px); }
    /* Resize handles of the selected node: knobs on the corners, invisible bars along the edges (so the fold toggle keeps the middle of the bottom edge). They keep their size on screen at any zoom. */
    .rm-handle { position: absolute; z-index: 3; touch-action: none; }
    .rm-handle[hidden] { display: none; }
    /* The arrow on the outer edge of a node: drag it onto another node to make that node a child of this one (REQ-015). It keeps its size on screen at any zoom. */
    .rm-arrow { position: absolute; top: 50%; right: calc(-25px * var(--rm-inv, 1)); z-index: 3; display: grid; place-items: center; width: calc(18px * var(--rm-inv, 1)); height: calc(18px * var(--rm-inv, 1)); margin-top: calc(-9px * var(--rm-inv, 1)); padding: 0; border: 1px solid var(--rm-line); border-radius: 50%; background: var(--rm-bar); color: var(--rm-muted); font-size: calc(11px * var(--rm-inv, 1)); line-height: 1; cursor: crosshair; opacity: 0; transition: opacity .12s, color .12s, border-color .12s; touch-action: none; }
    .rm-arrow::before { content: ''; position: absolute; top: 0; bottom: 0; left: calc(-8px * var(--rm-inv, 1)); width: calc(8px * var(--rm-inv, 1)); } /* bridges the gap to the node, so the hover is not lost on the way */
    .rm-node-wrap.arrow-left .rm-arrow { right: auto; left: calc(-25px * var(--rm-inv, 1)); transform: scaleX(-1); }
    .rm-node-wrap:hover .rm-arrow, .rm-node-wrap.selected .rm-arrow, .rm-node-wrap.connect-from .rm-arrow { opacity: 1; }
    .rm-arrow:hover, .rm-node-wrap.connect-from .rm-arrow { color: var(--accent-primary); border-color: var(--accent-primary); }
    .rm-node-wrap.connect-ok .rm-node { outline: 2px solid var(--accent-primary); outline-offset: 2px; }
    .rm-node-wrap.connect-no { opacity: .45; }
    .rm-viewport.is-connecting, .rm-viewport.is-connecting .rm-node { cursor: crosshair; }
    .rm-lines path[data-line="link-hit"] { fill: none; stroke: transparent; stroke-width: 14px; vector-effect: non-scaling-stroke; pointer-events: stroke; cursor: pointer; }
    .rm-lines path[data-line="connect"] { stroke: var(--accent-primary); stroke-dasharray: 3 5; }
    .rm-linkx { position: absolute; z-index: 4; transform: translate(-50%, -50%); display: grid; place-items: center; width: calc(20px * var(--rm-inv, 1)); height: calc(20px * var(--rm-inv, 1)); padding: 0; border: 1px solid var(--accent-primary); border-radius: 50%; background: var(--rm-bar); color: var(--rm-ink); cursor: pointer; box-shadow: var(--rm-pop); }
    .rm-linkx:hover { background: var(--rm-hover); }
    .rm-linkx svg { width: calc(10px * var(--rm-inv, 1)); height: calc(10px * var(--rm-inv, 1)); }
    .rm-handle[data-h="n"], .rm-handle[data-h="s"] { left: calc(10px * var(--rm-inv, 1)); right: calc(10px * var(--rm-inv, 1)); height: calc(8px * var(--rm-inv, 1)); cursor: ns-resize; }
    .rm-handle[data-h="n"] { top: calc(-4px * var(--rm-inv, 1)); }
    .rm-handle[data-h="s"] { bottom: calc(-4px * var(--rm-inv, 1)); }
    .rm-handle[data-h="e"], .rm-handle[data-h="w"] { top: calc(10px * var(--rm-inv, 1)); bottom: calc(10px * var(--rm-inv, 1)); width: calc(8px * var(--rm-inv, 1)); cursor: ew-resize; }
    .rm-handle[data-h="e"] { right: calc(-4px * var(--rm-inv, 1)); }
    .rm-handle[data-h="w"] { left: calc(-4px * var(--rm-inv, 1)); }
    .rm-handle[data-h="nw"], .rm-handle[data-h="ne"], .rm-handle[data-h="se"], .rm-handle[data-h="sw"] { box-sizing: border-box; width: calc(10px * var(--rm-inv, 1)); height: calc(10px * var(--rm-inv, 1)); border: 1.5px solid var(--accent-primary); border-radius: 2px; background: var(--rm-bar); }
    .rm-handle[data-h="nw"] { top: calc(-5px * var(--rm-inv, 1)); left: calc(-5px * var(--rm-inv, 1)); cursor: nwse-resize; }
    .rm-handle[data-h="ne"] { top: calc(-5px * var(--rm-inv, 1)); right: calc(-5px * var(--rm-inv, 1)); cursor: nesw-resize; }
    .rm-handle[data-h="sw"] { bottom: calc(-5px * var(--rm-inv, 1)); left: calc(-5px * var(--rm-inv, 1)); cursor: nesw-resize; }
    .rm-handle[data-h="se"] { bottom: calc(-5px * var(--rm-inv, 1)); right: calc(-5px * var(--rm-inv, 1)); cursor: nwse-resize; }
    /* An ellipse and a diamond do not fill their box: a thin frame ties the handles to the selected shape. */
    .rm-node-wrap.selected.shape-ellipse::before, .rm-node-wrap.selected.shape-diamond::before { content: ''; position: absolute; left: 0; top: 0; right: 0; bottom: 0; border: 1px dashed var(--accent-primary); opacity: .55; pointer-events: none; }
    .rm-handle[data-h="n"]:hover::after, .rm-handle[data-h="s"]:hover::after { content: ''; position: absolute; left: 0; right: 0; top: 50%; height: 2px; margin-top: -1px; background: var(--accent-primary); }
    .rm-handle[data-h="e"]:hover::after, .rm-handle[data-h="w"]:hover::after { content: ''; position: absolute; top: 0; bottom: 0; left: 50%; width: 2px; margin-left: -1px; background: var(--accent-primary); }
    .rm-node.has-color { background: var(--tint-dark); }
    html[data-theme="light"] .rm-node.has-color { background: var(--tint); }
    .rm-node[aria-pressed="true"] { border-color: var(--accent-primary); border-left-color: var(--branch, var(--b0)); box-shadow: 0 0 0 1px var(--accent-primary); }
    .rm-tri { position: absolute; top: 3px; right: 3px; z-index: 2; display: grid; place-items: center; width: 20px; height: 18px; padding: 0; border: 0; border-radius: 3px; background: transparent; color: var(--rm-ink); opacity: .55; cursor: pointer; font-size: 14px; line-height: 1; letter-spacing: -1px; }
    .rm-tri:hover, .rm-node-wrap.menu-open .rm-tri { opacity: 1; background: var(--rm-hover); }
    .rm-fold { position: absolute; left: 50%; bottom: -9px; z-index: 2; transform: translateX(-50%); display: inline-flex; align-items: center; justify-content: center; gap: 2px; min-width: 18px; height: 18px; padding: 0 5px; border: 1px solid var(--rm-line); border-radius: 9px; background: var(--rm-bar); color: var(--rm-muted); font-size: 10px; line-height: 1; cursor: pointer; }
    .rm-fold:hover { background: var(--rm-hover); color: var(--rm-ink); }
    .rm-fold.folded { border-color: var(--branch, var(--b0)); color: var(--rm-ink); }
    .rm-fold svg { width: 9px; height: 9px; }
    .rm-actions { position: absolute; z-index: 30; display: flex; flex-direction: column; min-width: 210px; max-height: calc(100% - 12px); overflow: auto; padding: 4px; border: 1px solid var(--rm-line); border-radius: 6px; background: var(--rm-bar); box-shadow: var(--rm-pop); cursor: default; }
    .rm-item { display: flex; align-items: center; gap: 8px; width: 100%; padding: 5px 9px; border: 0; border-radius: 3px; background: transparent; color: var(--rm-ink); text-align: left; white-space: nowrap; cursor: pointer; }
    .rm-item svg { flex: none; width: 14px; height: 14px; color: var(--rm-icon-fg); }
    .rm-item.ai svg { color: var(--accent-primary); }
    .rm-item:hover:not(:disabled) { background: var(--rm-hover); }
    .rm-item.danger { color: var(--accent-danger); }
    .rm-item.danger svg { color: var(--accent-danger); }
    .rm-item:disabled { opacity: .4; cursor: not-allowed; }
    .rm-item .rm-more { margin-left: auto; color: var(--rm-muted); }
    .rm-sep { height: 1px; margin: 4px 2px; background: var(--rm-line); }
    .rm-icon { display: inline-grid; place-items: center; flex: none; width: calc(26px * var(--ui-scale, 1)); height: calc(26px * var(--ui-scale, 1)); padding: 0; border: 0; border-radius: 3px; background: transparent; color: var(--rm-icon-fg); cursor: pointer; transition: background .15s, color .15s; }
    .rm-icon svg { width: 14px; height: 14px; }
    .rm-icon:hover:not(:disabled) { background: var(--rm-hover); color: var(--rm-ink); }
    .rm-layouts { display: flex; flex-direction: column; margin: 2px 0 2px 22px; padding: 2px 0 2px 6px; border-left: 1px solid var(--rm-line); }
    .rm-layouts button { display: flex; align-items: center; gap: 6px; padding: 4px 8px; border: 0; border-radius: 3px; background: transparent; color: var(--rm-ink); text-align: left; white-space: nowrap; cursor: pointer; }
    .rm-layouts button:hover { background: var(--rm-hover); }
    .rm-layouts button[aria-checked="true"] { font-weight: 600; }
    .rm-layouts .rm-check { width: 1em; color: var(--accent-primary); }
    .rm-divider { position: relative; flex: none; width: 5px; margin-left: -2px; border-left: 1px solid var(--rm-line); cursor: col-resize; touch-action: none; }
    .rm-divider:hover, .rm-divider:focus-visible { border-left-color: var(--accent-primary); background: var(--rm-hover); outline: none; }
    .rm-panel { display: flex; flex-direction: column; gap: 10px; flex: none; width: var(--rm-panel-width); min-width: ${PANEL_MIN}px; max-width: 60%; padding: 14px 12px; overflow: auto; background: var(--rm-bar); color: var(--rm-ink); }
    .rm-panel[hidden] { display: none; }
    .rm-panel-body { display: flex; flex: 1; flex-direction: column; gap: 10px; min-height: 0; }
    .rm-panel-body[hidden], .rm-empty[hidden], .rm-section[hidden] { display: none; }
    .rm-empty { margin: 0; color: var(--rm-muted); }
    .rm-panel input, .rm-panel textarea, .rm-dialog input, .rm-dialog textarea, .rm-dialog select { font: inherit; color: var(--rm-ink); }
    .rm-panel .rm-title-input { display: block; flex: none; width: 100%; min-height: 30px; padding: 4px 6px; border: 1px solid transparent; border-radius: 4px; background: transparent; font-size: calc(15px * var(--ui-scale, 1)); font-weight: 600; line-height: 1.3; resize: none; overflow: hidden; outline: none; }
    .rm-panel .rm-title-input:hover { border-color: var(--rm-line); }
    .rm-panel .rm-title-input:focus { border-color: var(--rm-focus); background: var(--rm-field); }
    .rm-error { margin: -4px 0 0; color: var(--rm-error); font-size: .95em; }
    .rm-error:empty { display: none; }
    .rm-ai { display: grid; grid-template-columns: 1fr 1fr; gap: 4px; }
    .rm-ai-btn { display: flex; align-items: center; gap: 5px; min-width: 0; padding: 4px 6px; border: 1px solid var(--rm-line); border-radius: 4px; background: transparent; color: var(--rm-ink); font-size: calc(11px * var(--ui-scale, 1)); text-align: left; white-space: nowrap; cursor: pointer; transition: background .15s; }
    .rm-ai-btn svg { flex: none; width: 13px; height: 13px; color: var(--accent-primary); }
    .rm-ai-label { min-width: 0; overflow: hidden; text-overflow: ellipsis; }
    .rm-ai-btn:hover:not(:disabled) { background: var(--rm-hover); }
    .rm-ai-btn:disabled { opacity: .45; cursor: not-allowed; }
    .rm-ai-note { margin: -4px 0 0; color: var(--rm-muted); font-size: .92em; }
    .rm-ai-note:empty { display: none; }
    .rm-tags { display: flex; flex-wrap: wrap; align-items: center; gap: 4px; }
    .rm-tag { display: inline-flex; align-items: center; gap: 4px; padding: 1px 7px; border: 1px solid var(--rm-line); border-radius: 10px; background: var(--rm-chip); color: var(--rm-ink); font-size: .92em; }
    .rm-tag button { padding: 0; border: 0; background: transparent; color: var(--rm-muted); font-size: 14px; line-height: 1; cursor: pointer; }
    .rm-tag button:hover { color: var(--rm-ink); }
    .rm-tag-input { flex: 1; min-width: 90px; padding: 3px 2px; border: 0; background: transparent; outline: none; }
    .rm-tag-input::placeholder, .rm-desc::placeholder { color: var(--rm-muted); }
    .rm-color-row, .rm-badge-row { display: flex; align-items: center; gap: 8px; color: var(--rm-muted); font-size: .95em; }
    .rm-badge-row { flex-wrap: wrap; gap: 8px 14px; }
    .rm-badge-row .rm-field { display: inline-flex; align-items: center; gap: 6px; }
    .rm-icon-pick, .rm-picture-pick { display: inline-flex; align-items: center; gap: 6px; min-width: 56px; height: 26px; padding: 0 8px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); color: var(--rm-ink); cursor: pointer; }
    .rm-icon-pick:hover, .rm-picture-pick:hover { background: var(--rm-hover); }
    .rm-picture-pick span { max-width: 130px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .rm-picture-thumb { display: block; width: 20px; height: 20px; object-fit: cover; border-radius: 3px; border: 1px solid var(--rm-line); }
    .rm-picture-thumb[hidden] { display: none; }
    .rm-dropzone { display: flex; flex-direction: column; align-items: center; gap: 10px; padding: 16px; border: 1px dashed var(--rm-line); border-radius: 6px; color: var(--rm-muted); text-align: center; outline: none; }
    .rm-dropzone:focus, .rm-dropzone.over { border-color: var(--accent-primary); }
    .rm-picture-preview { max-width: 100%; max-height: 160px; border-radius: 4px; border: 1px solid var(--rm-line); object-fit: contain; }
    .rm-picture-preview[hidden] { display: none; }
    .rm-node-wrap.picture-drop .rm-node { outline: 2px solid var(--accent-primary); outline-offset: 2px; }
    .rm-icon-pick .rm-glyph { color: var(--rm-ink); }
    .rm-number-input { width: 64px; height: 26px; padding: 2px 6px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); font: inherit; color: var(--rm-ink); outline: none; }
    .rm-number-input:focus { border-color: var(--rm-focus); }
    .rm-look-row { display: flex; align-items: center; flex-wrap: wrap; gap: 6px 8px; color: var(--rm-muted); font-size: .95em; }
    .rm-look-row > span:first-child { flex: none; min-width: 3.4em; }
    .rm-seg { display: inline-flex; border: 1px solid var(--rm-line); border-radius: 4px; overflow: hidden; background: var(--rm-field); }
    .rm-seg button { display: inline-grid; place-items: center; min-width: 30px; height: 26px; padding: 0 8px; border: 0; border-left: 1px solid var(--rm-line); background: transparent; color: var(--rm-ink); font: inherit; cursor: pointer; }
    .rm-seg button:first-child { border-left: 0; }
    .rm-seg button:hover { background: var(--rm-hover); }
    .rm-seg button[aria-pressed="true"] { background: var(--accent-fill); color: var(--on-accent); }
    .rm-seg button svg { width: 16px; height: 16px; }
    .rm-dim { display: inline-flex; align-items: center; gap: 4px; }
    .rm-dim input { width: 62px; height: 26px; padding: 2px 6px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); font: inherit; color: var(--rm-ink); outline: none; }
    .rm-dim input:focus { border-color: var(--rm-focus); }
    .rm-dim input::placeholder { color: var(--rm-muted); }
    .rm-icongrid { display: grid; grid-template-columns: repeat(auto-fill, minmax(34px, 1fr)); gap: 4px; }
    .rm-icongrid button { display: grid; place-items: center; height: 34px; padding: 0; border: 1px solid transparent; border-radius: 4px; background: transparent; color: var(--rm-ink); cursor: pointer; }
    .rm-icongrid button:hover { background: var(--rm-hover); }
    .rm-icongrid button[aria-pressed="true"] { border-color: var(--accent-primary); background: var(--rm-active); }
    .rm-icongrid svg { width: 18px; height: 18px; }
    .rm-color-row input[type=color] { width: 30px; height: 24px; padding: 1px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); cursor: pointer; }
    .rm-panel h3 { margin: 6px 0 0; font-size: .82em; font-weight: 600; letter-spacing: .04em; text-transform: uppercase; color: var(--rm-muted); }
    .rm-format { display: flex; flex-wrap: wrap; gap: 2px; }
    .rm-format .rm-icon { font-size: .95em; font-weight: 700; }
    .rm-desc { flex: none; width: 100%; height: 180px; min-height: 80px; box-sizing: border-box; padding: 8px 10px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); line-height: 1.55; resize: vertical; outline: none; }
    .rm-desc:focus { border-color: var(--rm-focus); }
    .rm-visual-pane { display: flex; flex-direction: column; gap: 8px; }
    .rm-visual-pane[hidden], .rm-visual-pane [hidden] { display: none; }
    .rm-vis-panel { padding: 8px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); overflow: auto; max-height: 340px; }
    .rm-vis-panel img { margin: 0 auto; }
    .rm-visual-pane .rm-chip-btn { align-self: flex-start; border: 1px solid var(--rm-line); }
    .rm-visual-pane .rm-vis-source { flex: none; width: 100%; height: 120px; min-height: 60px; box-sizing: border-box; padding: 8px 10px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .9em; line-height: 1.45; resize: vertical; outline: none; }
    .rm-visual-pane .rm-vis-source:focus { border-color: var(--rm-focus); }
    .rm-visual-pane .rm-image-input { width: 100%; box-sizing: border-box; padding: 6px 8px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); outline: none; }
    .rm-visual-pane .rm-image-input:focus { border-color: var(--rm-focus); }
    .rm-draw-list { display: flex; flex-direction: column; gap: 2px; padding: 4px; border: 1px solid var(--rm-line); border-radius: 4px; }
    .rm-draw-list[hidden] { display: none; }
    .rm-draw-list button { padding: 4px 8px; border: 0; border-radius: 3px; background: transparent; color: var(--rm-ink); text-align: left; cursor: pointer; }
    .rm-draw-list button:hover { background: var(--rm-hover); }
    .rm-icongrid button:focus-visible, .rm-icon-pick:focus-visible, .rm-tool:focus-visible, .rm-icon:focus-visible, .rm-tbtn:focus-visible, .rm-item:focus-visible, .rm-ai-btn:focus-visible, .rm-chip-btn:focus-visible, .rm-fold:focus-visible, .rm-tri:focus-visible, .rm-node:focus-visible { outline: 2px solid var(--rm-focus); outline-offset: 1px; }
    .rm-section { display: flex; flex: none; flex-direction: column; gap: 6px; }
    .rm-list { margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: 6px; }
    .rm-ev-row { display: flex; flex-direction: column; gap: 3px; padding: 6px 8px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); }
    .rm-ev-chip { align-self: flex-start; padding: 0 7px; border-radius: 999px; background: var(--rm-chip); color: var(--rm-ink); font-size: .8em; font-weight: 600; white-space: nowrap; }
    .rm-ev-chip[data-label="Project fact"] { background: rgba(78, 201, 176, .18); color: #4ec9b0; }
    .rm-ev-chip[data-label="External fact"] { background: rgba(86, 156, 214, .20); color: #7cb7e8; }
    .rm-ev-chip[data-label="AI inference"] { background: rgba(197, 134, 192, .20); color: #d7a0d2; }
    .rm-ev-chip[data-label="Open assumption"] { background: rgba(206, 145, 120, .20); color: #e0a98f; }
    html[data-theme="light"] .rm-ev-chip[data-label="Project fact"] { background: rgba(34, 134, 58, .14); color: #1a6e30; }
    html[data-theme="light"] .rm-ev-chip[data-label="External fact"] { background: rgba(3, 102, 214, .12); color: #0550ae; }
    html[data-theme="light"] .rm-ev-chip[data-label="AI inference"] { background: rgba(130, 80, 223, .14); color: #6a3fc0; }
    html[data-theme="light"] .rm-ev-chip[data-label="Open assumption"] { background: rgba(176, 136, 0, .16); color: #7a5f00; }
    .rm-ev-text { overflow-wrap: anywhere; }
    .rm-ev-source { align-self: flex-start; max-width: 100%; padding: 0; border: 0; background: transparent; color: var(--accent-primary); font-size: .92em; text-align: left; text-decoration: underline; overflow-wrap: anywhere; cursor: pointer; }
    .rm-conn-row { display: flex; align-items: center; gap: 6px; padding: 2px 3px 2px 8px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); }
    .rm-conn-name { flex: 1; min-width: 0; padding: 0; border: 0; background: transparent; color: var(--rm-ink); text-align: left; overflow-wrap: anywhere; cursor: pointer; }
    .rm-x { display: inline-grid; place-items: center; flex: none; width: 20px; height: 20px; padding: 0; border: 0; border-radius: 3px; background: transparent; color: var(--rm-muted); cursor: pointer; }
    .rm-x:hover { background: var(--rm-hover); color: var(--rm-ink); }
    .rm-x svg { width: 11px; height: 11px; }
    .rm-modal { position: absolute; inset: 0; z-index: 50; display: flex; align-items: center; justify-content: center; padding: 16px; background: rgba(0, 0, 0, 0.45); }
    .rm-dialog { width: 100%; max-width: 440px; max-height: 90%; overflow: auto; border: 1px solid var(--rm-line); border-radius: 8px; background: var(--rm-bar); color: var(--rm-ink); box-shadow: var(--shadow-lg); }
    .rm-dialog h2 { margin: 0; padding: 14px 18px 0; font-size: 1.15em; font-weight: 600; }
    .rm-dialog-body { display: flex; flex-direction: column; gap: 10px; padding: 10px 18px; }
    .rm-dialog-body p { margin: 0; overflow-wrap: anywhere; }
    .rm-dialog label { display: flex; flex-direction: column; gap: 4px; color: var(--rm-muted); font-size: .95em; }
    .rm-dialog input, .rm-dialog textarea, .rm-dialog select { width: 100%; min-height: 28px; padding: 4px 8px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); outline: none; }
    .rm-dialog textarea { min-height: 84px; line-height: 1.5; resize: vertical; }
    .rm-dialog input:focus, .rm-dialog textarea:focus, .rm-dialog select:focus { border-color: var(--rm-focus); }
    .rm-dialog-actions { display: flex; justify-content: flex-end; gap: 8px; padding: 6px 18px 14px; }
    .rm-btn { min-height: 26px; padding: 3px 14px; border: 1px solid var(--rm-line); border-radius: 4px; background: transparent; color: var(--rm-ink); cursor: pointer; }
    .rm-btn:hover { background: var(--rm-hover); }
    .rm-btn.primary { border-color: var(--rm-primary); background: var(--rm-primary); color: var(--on-rm-primary); }
    .rm-btn.primary:hover { background: var(--rm-primary-hover); }
    .rm-btn.danger { border-color: var(--rm-danger); background: var(--rm-danger); color: var(--on-rm-danger); }
    .rm-toast { position: absolute; left: 50%; bottom: 40px; z-index: 60; transform: translateX(-50%); max-width: 70%; padding: 6px 12px; border: 1px solid var(--rm-line); border-radius: 6px; background: var(--rm-chip); color: var(--rm-ink); box-shadow: var(--rm-pop); pointer-events: none; }
    .rm-toast[hidden] { display: none; }
    .rm-problem { display: none; align-items: center; gap: 10px; padding: 4px 12px; background: var(--rm-warn-bg, rgba(206, 145, 120, 0.16)); color: var(--rm-warn-fg, var(--accent-warning)); font-size: calc(12px * var(--ui-scale, 1)); border-bottom: 1px solid var(--border-color); }
    .rm-problem.visible { display: flex; }
    .rm-problem span { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .rm-problem button { border: 0; background: transparent; color: inherit; cursor: pointer; font-size: 14px; }
    @media (max-width: 760px) {
        .rm-workspace { flex-direction: column; }
        .rm-left { flex: none; height: 58vh; min-height: 300px; }
        .rm-divider { display: none; }
        .rm-panel { width: 100%; max-width: none; min-width: 0; min-height: 240px; border-top: 1px solid var(--rm-line); }
    }
    `;
  const styleEl = document.createElement("style");
  styleEl.id = "research-map-style";
  styleEl.textContent = css;
  document.head.appendChild(styleEl);
  const el = {};
  A.el = el;
  function tool(act, label, content, handler) {
    return h("button", { class: "rm-tool", type: "button", "data-act": act, title: label, "aria-label": label, onClick: handler }, content);
  }
  const VIEWS = [["map", "Map", "The mind map"], ["view", "View", "The file as ordinary Markdown"], ["source", "Source", "The Markdown source"]];
  function modeSwitch() {
    return h("div", { class: "mv-modes", role: "group", "aria-label": "View of this map" }, VIEWS.map(function(v) {
      return h("button", { type: "button", "data-view": v[0], "aria-pressed": "false", title: v[2], onClick: function() {
        A.showView(v[0]);
      } }, v[1]);
    }));
  }
  el.modes = modeSwitch();
  el.title = h("strong");
  el.question = h("span");
  el.status = h("div", { class: "rm-status", hidden: true, "aria-live": "polite" });
  el.queryCount = h("span", { class: "rm-count" });
  el.queriesBtn = tool("queries", "Web searches the research ran", [icon("search"), el.queryCount], function(e) {
    e.stopPropagation();
    A.toggleQueries();
  });
  el.queriesBtn.hidden = true;
  el.zoom = h("span", { class: "rm-zoom", "aria-live": "polite" });
  el.popover = h("div", { class: "rm-popover", hidden: true, role: "dialog", "aria-label": "Web searches" });
  function tbtn(act, label, title, handler, extra) {
    return h("button", { class: "rm-tbtn", type: "button", "data-act": act, title, onClick: handler }, extra || null, label);
  }
  el.exportBtn = tbtn("export", "Export", "Export the map as a Markdown report or a PDF", function(e) {
    e.stopPropagation();
    A.toggleExport();
  }, icon("download"));
  el.exportBtn.setAttribute("aria-haspopup", "true");
  el.exportBtn.setAttribute("aria-expanded", "false");
  el.exportBtn.appendChild(icon("chevron"));
  el.exportMenu = h(
    "div",
    { class: "rm-exportmenu", role: "menu", "aria-label": "Export", hidden: true },
    h("button", { class: "rm-item", type: "button", role: "menuitem", "data-act": "export-markdown", title: "The AI writes a report of the whole map as a document you can share, saved as Markdown", onClick: function(e) {
      e.stopPropagation();
      A.closeExport();
      A.exportDialog("markdown");
    } }, icon("text"), h("span", null, "Markdown report\u2026")),
    h("button", { class: "rm-item", type: "button", role: "menuitem", "data-act": "export-pdf", title: "The same report as a PDF", onClick: function(e) {
      e.stopPropagation();
      A.closeExport();
      A.exportDialog("pdf");
    } }, icon("download"), h("span", null, "PDF\u2026")),
    h("div", { class: "rm-sep", role: "separator" }),
    h("button", { class: "rm-item", type: "button", role: "menuitem", "data-act": "translate", title: "The AI translates this map into another language", onClick: function(e) {
      e.stopPropagation();
      A.closeExport();
      A.translateDialog();
    } }, icon("text"), h("span", null, "Translate map\u2026"))
  );
  el.collapseBtn = tbtn("collapse-all", "Collapse all", "Fold every branch so that only the root and its main branches show", function() {
    A.collapseAll();
  });
  el.expandBtn = tbtn("expand-all", "Expand all", "Show every node", function() {
    A.expandAll();
  });
  el.toolbar = h(
    "div",
    { class: "rm-toolbar" },
    el.modes,
    h("div", { class: "rm-heading" }, el.title, el.question),
    el.status,
    el.queriesBtn,
    el.collapseBtn,
    el.expandBtn,
    el.exportBtn,
    h("span", { class: "rm-tsep", "aria-hidden": "true" }),
    tool("zoom-out", "Zoom out", icon("minus"), function() {
      A.zoomAtCentre(rm.view.scale / 1.2);
    }),
    el.zoom,
    tool("zoom-in", "Zoom in", icon("plus"), function() {
      A.zoomAtCentre(rm.view.scale * 1.2);
    }),
    tool("centre", "Centre the map on the root node at 100%", icon("centre"), function() {
      A.centreView();
    }),
    el.popover,
    el.exportMenu
  );
  el.svg = document.createElementNS(NS, "svg");
  el.svg.setAttribute("class", "rm-lines");
  el.svg.setAttribute("aria-hidden", "true");
  el.world = h("div", { class: "rm-world" }, el.svg);
  el.loading = h("div", { class: "rm-loading" }, "Loading the research map\u2026");
  el.viewport = h("div", { class: "rm-viewport", tabindex: "0", role: "region", "aria-label": "Research map. Drag the background to move the map and drag nodes to change their positions." }, el.world, el.loading);
  el.hint = h("div", { class: "rm-hint" }, "Drag the map and nodes \xB7 the mouse wheel zooms");
  el.readout = h("div", { class: "rm-readout", hidden: true });
  el.left = h("section", { class: "rm-left", "aria-label": "Research map" }, el.viewport, el.hint, el.readout);
  el.divider = h("div", { class: "rm-divider", role: "separator", tabindex: "0", "aria-label": "Resize properties panel", "aria-orientation": "vertical", "aria-valuemin": String(PANEL_MIN), "aria-valuemax": String(PANEL_MAX) });
  el.panel = h("aside", { class: "rm-panel", "aria-label": "Node properties" });
  el.workspace = h("div", { class: "rm-workspace" }, el.left, el.divider, el.panel);
  el.toast = h("div", { class: "rm-toast", hidden: true, role: "status" });
  el.root = h("div", { class: "rm-root", id: "research-map-container" }, el.toolbar, el.workspace, el.toast);
  host.appendChild(el.root);
  el.problemText = h("span");
  el.problem = h("div", { class: "rm-problem", id: "research-map-problem", role: "alert" }, el.problemText, h("button", { type: "button", "aria-label": "Dismiss", onClick: function() {
    A.hideProblem();
  } }, "\u2715"));
  if (host.parentNode) host.parentNode.insertBefore(el.problem, host);
  function buildPanel() {
    el.empty = h("p", { class: "rm-empty" }, "Select a node on the map");
    el.titleInput = h("textarea", { class: "rm-title-input", rows: "1", maxlength: String(MAX_TITLE), "aria-label": "Node name", spellcheck: "false" });
    el.titleError = h("p", { class: "rm-error", role: "alert" });
    el.tagInput = h("input", { class: "rm-tag-input", maxlength: String(MAX_TITLE), placeholder: "Add tag", "aria-label": "Add tag" });
    el.tags = h("div", { class: "rm-tags" }, el.tagInput);
    el.color = h("input", { class: "rm-color-input", type: "color", "aria-label": "Node color", title: "Node color" });
    el.colorClear = h("button", { class: "rm-x", type: "button", title: "Use the branch colour", "aria-label": "Use the branch colour" }, icon("close"));
    el.iconPick = h("button", { class: "rm-icon-pick", type: "button", "data-act": "icon", title: "Choose an icon for this node", onClick: function() {
      A.iconDialog(A.nodeById(rm.selected));
    } });
    el.iconGlyph = h("span", { class: "rm-glyph", "aria-hidden": "true" });
    el.iconText = h("span", null, "None");
    el.iconPick.appendChild(el.iconGlyph);
    el.iconPick.appendChild(el.iconText);
    el.iconClear = h("button", { class: "rm-x", type: "button", "data-act": "icon-clear", title: "Remove the icon", "aria-label": "Remove the icon" }, icon("close"));
    el.imageThumb = h("img", { class: "rm-picture-thumb", alt: "", hidden: true });
    el.imageText = h("span", null, "None");
    el.imagePick = h("button", { class: "rm-picture-pick", type: "button", "data-act": "image", title: "Choose a picture for this node, shown beside its icon", onClick: function() {
      A.pictureDialog(A.nodeById(rm.selected));
    } }, el.imageThumb, el.imageText);
    el.imageClear = h("button", { class: "rm-x", type: "button", "data-act": "image-clear", title: "Remove the picture", "aria-label": "Remove the picture" }, icon("close"));
    el.numberInput = h("input", { class: "rm-number-input", type: "number", min: "1", max: String(MAX_NUMBER), step: "1", inputmode: "numeric", "aria-label": "Number badge", title: "A number shown before the title (1 to " + MAX_NUMBER + "); leave it empty for none", placeholder: "\u2014" });
    el.shapeBtns = {};
    SHAPE_IDS.forEach(function(id) {
      el.shapeBtns[id] = h("button", { type: "button", "data-shape": id, "aria-pressed": "false", onClick: function() {
        if (rm.selected) queueUpdate(rm.selected, { shape: id === "rounded" ? "" : id }, true);
      } }, icon(id, SHAPE_PATHS));
    });
    el.shapeSeg = h("div", { class: "rm-seg", role: "group", "aria-label": "Node shape" }, SHAPE_IDS.map(function(id) {
      return el.shapeBtns[id];
    }));
    el.sizeBtns = {};
    const sizeButton = function(id, label, title, patch) {
      el.sizeBtns[id] = h("button", { type: "button", "data-size": id, "aria-pressed": "false", title, onClick: function() {
        if (rm.selected) queueUpdate(rm.selected, patch, true);
      } }, label);
      return el.sizeBtns[id];
    };
    el.sizeSeg = h(
      "div",
      { class: "rm-seg", role: "group", "aria-label": "Node size" },
      sizeButton("auto", "Auto", "Fit the size to the title", { width: null, height: null }),
      SIZE_PRESETS.map(function(p) {
        return sizeButton(p.id, p.label, "Width " + p.w + ", height " + p.h, { width: p.w, height: p.h });
      })
    );
    el.widthInput = h("input", { type: "number", step: "1", inputmode: "numeric", "data-dim": "width", "aria-label": "Node width", placeholder: "Auto" });
    el.heightInput = h("input", { type: "number", step: "1", inputmode: "numeric", "data-dim": "height", "aria-label": "Node height", placeholder: "Auto" });
    el.desc = h("textarea", { class: "rm-desc", "aria-label": "Markdown description", placeholder: "Add a Markdown description" });
    el.visualBtns = {};
    VISUAL_KINDS.forEach(function(kind) {
      el.visualBtns[kind[0]] = h("button", { type: "button", "data-visual": kind[0], "aria-pressed": "false", onClick: function() {
        if (rm.selected) queueUpdate(rm.selected, { visual: kind[0] === "text" ? "" : kind[0] }, true);
      } }, kind[1]);
    });
    el.visualSeg = h("div", { class: "rm-seg", role: "group", "aria-label": "What the node shows" }, VISUAL_KINDS.map(function(kind) {
      return el.visualBtns[kind[0]];
    }));
    el.visualPreview = h("div", { class: "rm-vis rm-vis-panel" });
    el.visualExpand = h("button", { class: "rm-chip-btn", type: "button", title: "Open full screen: wheel to zoom, drag to move, Esc to close", onClick: function() {
      A.expandVisual(rm.selected);
    } }, icon("open"), "Expand");
    el.visualSource = h("textarea", { class: "rm-vis-source", "aria-label": "Mermaid source", placeholder: "Paste or type Mermaid, for example: sequenceDiagram", spellcheck: "false" });
    el.imageInput = h("input", { type: "text", class: "rm-image-input", "aria-label": "Image address or project path", placeholder: "images/screen.png or https://\u2026", spellcheck: "false" });
    el.visualPane = h("div", { class: "rm-visual-pane", hidden: true }, el.visualPreview, el.visualExpand, el.visualSource, el.imageInput);
    el.shapeRow = h("div", { class: "rm-look-row" }, h("span", null, "Shape"), el.shapeSeg);
    el.drawBtn = h(
      "button",
      { class: "rm-ai-btn", type: "button", "data-act": "draw", "aria-expanded": "false", title: "The AI draws a diagram of this node as a child node", onClick: function() {
        A.toggleDrawList();
      } },
      icon("diagram"),
      h("span", { class: "rm-ai-label" }, "Draw"),
      h("span", { class: "rm-more", "aria-hidden": "true" }, "\u25BE")
    );
    el.drawList = h("div", { class: "rm-draw-list", role: "menu", "aria-label": "Diagram types", hidden: true });
    const fmt = function(label, text, before, after, placeholder) {
      return h("button", { class: "rm-icon", type: "button", title: label, "aria-label": label, "data-fmt": label.toLowerCase(), onClick: function() {
        insertMarkdown(before, after, placeholder);
      } }, text);
    };
    el.format = h(
      "div",
      { class: "rm-format", "aria-label": "Markdown formatting", role: "group" },
      fmt("Bold", "B", "**", "**", "text"),
      fmt("Italic", "I", "*", "*", "text"),
      fmt("Link", "\u2197", "[", "](url)", "text"),
      fmt("Image", "\u25A7", "![", "](image url)", "description"),
      fmt("List", "\u2637", "- ", "", "item")
    );
    el.evHeading = h("h3", null, "Evidence");
    el.evList = h("ul", { class: "rm-list" });
    el.evSection = h("div", { class: "rm-section", hidden: true }, el.evHeading, el.evList);
    el.connHeading = h("h3", null, "Connections");
    el.connList = h("ul", { class: "rm-list" });
    el.connSection = h("div", { class: "rm-section", hidden: true }, el.connHeading, el.connList);
    el.aiButtons = AI_ACTIONS.map(function(action) {
      return h("button", { class: "rm-ai-btn", type: "button", "data-act": action.act, title: action.hint, onClick: function() {
        A.runAI(action.act, A.nodeById(rm.selected));
      } }, icon(action.icon), h("span", { class: "rm-ai-label" }, action.label));
    });
    el.aiButtons.push(el.drawBtn);
    el.aiNote = h("p", { class: "rm-ai-note" });
    el.body = h(
      "div",
      { class: "rm-panel-body", hidden: true },
      el.titleInput,
      el.titleError,
      h("h3", null, "AI"),
      h("div", { class: "rm-ai", role: "group", "aria-label": "AI actions on this node" }, el.aiButtons),
      el.drawList,
      el.aiNote,
      el.tags,
      h("div", { class: "rm-color-row" }, h("span", null, "Color"), el.color, el.colorClear),
      h(
        "div",
        { class: "rm-badge-row" },
        h("div", { class: "rm-field" }, h("span", null, "Icon"), el.iconPick, el.iconClear),
        h("div", { class: "rm-field" }, h("span", null, "Number"), el.numberInput)
      ),
      h("div", { class: "rm-badge-row" }, h("div", { class: "rm-field" }, h("span", null, "Picture"), el.imagePick, el.imageClear)),
      el.shapeRow,
      h("div", { class: "rm-look-row" }, h("span", null, "Size"), el.sizeSeg),
      h(
        "div",
        { class: "rm-look-row" },
        h("span", null),
        h("label", { class: "rm-dim", title: "Width in pixels; empty is automatic. The title wraps inside it." }, "W", el.widthInput),
        h("label", { class: "rm-dim", title: "Height in pixels; empty is automatic. The node never gets lower than its title." }, "H", el.heightInput)
      ),
      h("div", { class: "rm-look-row" }, h("span", null, "Content"), el.visualSeg),
      el.visualPane,
      h("h3", null, "Description"),
      el.format,
      el.desc,
      el.evSection,
      el.connSection
    );
    el.panel.appendChild(el.empty);
    el.panel.appendChild(el.body);
    if (window.ResizeObserver) {
      let lastWidth = 0;
      new ResizeObserver(function() {
        const width = el.titleInput.offsetWidth;
        if (width !== lastWidth) {
          lastWidth = width;
          fitTitle();
        }
      }).observe(el.titleInput);
    }
    el.titleInput.addEventListener("keydown", function(event) {
      if (event.key === "Enter") {
        event.preventDefault();
        el.titleInput.blur();
      }
    });
    el.titleInput.addEventListener("input", function() {
      fitTitle();
      const id = rm.selected;
      if (!id) return;
      const value = el.titleInput.value.trim().replace(/\s*\n\s*/g, " ");
      if (!value) {
        el.titleError.textContent = "Enter a node name.";
        return;
      }
      el.titleError.textContent = "";
      queueUpdate(id, { title: value });
      const entry = rm.els.get(id);
      if (entry) entry.label.textContent = value;
    });
    el.titleInput.addEventListener("blur", function() {
      const id = rm.selected;
      if (!id) return;
      flushUpdate(id);
      const node = A.nodeById(id);
      if (!el.titleInput.value.trim()) {
        el.titleInput.value = node ? node.title : "";
        el.titleError.textContent = "";
      } else el.titleInput.value = el.titleInput.value.trim();
    });
    el.tagInput.addEventListener("keydown", function(event) {
      if (event.key !== "Enter") return;
      event.preventDefault();
      const node = A.nodeById(rm.selected);
      const value = el.tagInput.value.trim().slice(0, MAX_TITLE);
      if (!node || !value) return;
      el.tagInput.value = "";
      if (node.tags.some(function(t) {
        return t.toLocaleLowerCase() === value.toLocaleLowerCase();
      })) return;
      queueUpdate(node.id, { tags: node.tags.concat([value]) }, true);
    });
    el.color.addEventListener("input", function() {
      if (rm.selected) queueUpdate(rm.selected, { color: el.color.value.toLowerCase() });
    });
    el.color.addEventListener("change", function() {
      if (rm.selected) queueUpdate(rm.selected, { color: el.color.value.toLowerCase() }, true);
    });
    el.colorClear.addEventListener("click", function() {
      if (rm.selected) queueUpdate(rm.selected, { color: "" }, true);
    });
    el.iconClear.addEventListener("click", function() {
      if (rm.selected) queueUpdate(rm.selected, { icon: "" }, true);
    });
    el.imageClear.addEventListener("click", function() {
      if (rm.selected) queueUpdate(rm.selected, { image: "" }, true);
    });
    const sendNumber = function() {
      if (!rm.selected) return;
      const raw = el.numberInput.value.trim();
      const value = raw === "" ? null : Math.floor(Number(raw));
      if (value !== null && !(value >= 1 && value <= MAX_NUMBER)) {
        A.toast("A number is between 1 and " + MAX_NUMBER + ".");
        A.fillPanel(true);
        return;
      }
      const node = A.nodeById(rm.selected);
      if (node && (node.number == null ? null : node.number) === value) return;
      queueUpdate(rm.selected, { number: value }, true);
    };
    el.numberInput.addEventListener("change", sendNumber);
    el.numberInput.addEventListener("keydown", function(event) {
      if (event.key === "Enter") {
        event.preventDefault();
        sendNumber();
        el.numberInput.blur();
      }
    });
    const sendSize = function(key, input) {
      if (!rm.selected) return;
      const range = LIMITS[key], raw = input.value.trim();
      const value = raw === "" ? null : Math.round(Number(raw));
      if (value !== null && !(value >= range[0] && value <= range[1])) {
        A.toast("A " + key + " is between " + range[0] + " and " + range[1] + ".");
        A.fillPanel(true);
        return;
      }
      const node = A.nodeById(rm.selected);
      if (node && A.boxOf(node)[key] === value) return;
      queueUpdate(rm.selected, key === "width" ? { width: value } : { height: value }, true);
    };
    [el.widthInput, el.heightInput].forEach(function(input) {
      const key = input.getAttribute("data-dim");
      input.addEventListener("change", function() {
        sendSize(key, input);
      });
      input.addEventListener("keydown", function(event) {
        if (event.key === "Enter") {
          event.preventDefault();
          sendSize(key, input);
          input.blur();
        }
      });
    });
    el.desc.addEventListener("input", function() {
      if (rm.selected) queueUpdate(rm.selected, { description: el.desc.value });
    });
    el.desc.addEventListener("blur", function() {
      if (rm.selected) flushUpdate(rm.selected);
    });
    el.visualSource.addEventListener("input", function() {
      if (rm.selected) queueUpdate(rm.selected, { description: withDiagram(A.currentDescription(rm.selected), el.visualSource.value) });
    });
    el.visualSource.addEventListener("blur", function() {
      if (rm.selected) flushUpdate(rm.selected);
    });
    el.imageInput.addEventListener("input", function() {
      const node = A.nodeById(rm.selected);
      if (node) queueUpdate(node.id, { description: withImage(A.currentDescription(node.id), (imageOf(A.currentDescription(node.id)) || {}).alt || node.title, el.imageInput.value) });
    });
    el.imageInput.addEventListener("blur", function() {
      if (rm.selected) flushUpdate(rm.selected);
    });
  }
  function fitTitle() {
    const box = el.titleInput;
    if (!box.offsetParent) return;
    box.style.height = "auto";
    box.style.height = box.scrollHeight + box.offsetHeight - box.clientHeight + "px";
  }
  function insertMarkdown(before, after, placeholder) {
    const area = el.desc, start = area.selectionStart, end = area.selectionEnd, value = area.value;
    const chosen = value.slice(start, end) || placeholder;
    area.value = value.slice(0, start) + before + chosen + after + value.slice(end);
    area.dispatchEvent(new Event("input", { bubbles: true }));
    area.focus();
    area.setSelectionRange(start + before.length, start + before.length + chosen.length);
  }
  buildPanel();
})(window.MVResearchMapView);
;
(function(A) {
  "use strict";
  if (!A.ready) return;
  const {
    BRANCH_COLOURS,
    CARD_BOX,
    HANDLES,
    LIMITS,
    Layout,
    MAX_NUMBER,
    MAX_SCALE,
    MIN_SCALE,
    NODE_ICONS,
    NS,
    PANEL_DEFAULT,
    PANEL_MAX,
    PANEL_MIN,
    SHAPE_FIT,
    SHAPE_IDS,
    SHAPE_NAMES,
    clamp,
    el,
    fillVisual,
    h,
    icon,
    loadSaved,
    mix,
    now,
    readableOn,
    reportError,
    rm,
    saveSoon,
    send,
    setGlyph,
    setThumb,
    visualOf
  } = A;
  Object.assign(A, {
    boxOf,
    branchHex,
    clearLink,
    closeQueries,
    collapseAll,
    drawLines,
    expandAll,
    expandVisual,
    focusNode,
    hideProblem,
    nodeById,
    relayout,
    remeasure,
    removeSelectedLink,
    render,
    reveal,
    selectLink,
    startResize,
    stopTicker,
    syncVisual,
    toast,
    toggleQueries
  });
  function nodeById(id) {
    if (!rm.snap || !id) return null;
    return rm.snap.byId.get(id) || null;
  }
  function text(value) {
    return typeof value === "string" ? value : value == null ? "" : String(value);
  }
  function limited(value, range) {
    return typeof value === "number" && isFinite(value) && Math.floor(value) === value && value >= range[0] && value <= range[1] ? value : null;
  }
  function adoptLimits(raw) {
    const pair = function(value, fallback) {
      return Array.isArray(value) && value.length === 2 && value.every(Number.isInteger) && value[0] > 0 && value[0] <= value[1] ? value.slice() : fallback;
    };
    const given = raw && typeof raw === "object" ? raw : {};
    LIMITS.width = pair(given.width, LIMITS.width);
    LIMITS.height = pair(given.height, LIMITS.height);
  }
  function normalise(raw) {
    const snap = { ok: true, problem: "" };
    if (!raw || typeof raw !== "object") return { ok: false, problem: "The map data is missing." };
    if (raw.ok === false) return { ok: false, problem: text(raw.problem) || "This file cannot be shown as a research map." };
    adoptLimits(raw.sizeLimits);
    const nodes = [];
    const seen = /* @__PURE__ */ new Set();
    (Array.isArray(raw.nodes) ? raw.nodes : []).forEach(function(n) {
      if (!n || typeof n.id !== "string" || !n.id || seen.has(n.id)) return;
      seen.add(n.id);
      nodes.push({
        id: n.id,
        parent: text(n.parent),
        title: text(n.title),
        tags: (Array.isArray(n.tags) ? n.tags : []).map(text).filter(Boolean),
        color: /^#[0-9a-f]{6}$/i.test(n.color || "") ? n.color.toLowerCase() : "",
        icon: text(n.icon),
        image: text(n.image),
        number: typeof n.number === "number" && isFinite(n.number) && n.number >= 1 && n.number <= MAX_NUMBER && Math.floor(n.number) === n.number ? n.number : null,
        shape: SHAPE_IDS.indexOf(text(n.shape)) > 0 ? n.shape : "",
        visual: text(n.visual) === "diagram" || text(n.visual) === "image" ? n.visual : "",
        width: limited(n.width, LIMITS.width),
        height: limited(n.height, LIMITS.height),
        description: text(n.description),
        layout: text(n.layout),
        x: typeof n.x === "number" && isFinite(n.x) ? n.x : null,
        y: typeof n.y === "number" && isFinite(n.y) ? n.y : null,
        evidence: (Array.isArray(n.evidence) ? n.evidence : []).filter(Boolean).map(function(e) {
          return { label: text(e.label), text: text(e.text), source: text(e.source) };
        })
      });
    });
    if (!nodes.length) return { ok: false, problem: "The research map has no nodes." };
    snap.id = text(raw.id);
    snap.title = text(raw.title);
    snap.question = text(raw.question);
    snap.status = text(raw.status);
    snap.incomplete = text(raw.incomplete);
    const job = raw.job && typeof raw.job === "object" ? raw.job : null;
    snap.job = job ? { kind: text(job.kind), label: text(job.label), step: text(job.step), startedAt: typeof job.startedAt === "number" ? job.startedAt : 0 } : null;
    snap.webQueries = (Array.isArray(raw.webQueries) ? raw.webQueries : []).map(text).filter(Boolean);
    snap.nodes = nodes;
    snap.byId = new Map(nodes.map(function(n) {
      return [n.id, n];
    }));
    snap.links = (Array.isArray(raw.links) ? raw.links : []).filter(function(l) {
      return l && snap.byId.has(l.from) && snap.byId.has(l.to) && l.from !== l.to;
    }).map(function(l) {
      return { from: l.from, to: l.to };
    });
    snap.layouts = (Array.isArray(raw.layouts) ? raw.layouts : []).filter(function(l) {
      return l && typeof l.id === "string";
    }).map(function(l) {
      return { id: l.id, name: text(l.name) || l.id };
    });
    snap.drawKinds = (Array.isArray(raw.drawKinds) ? raw.drawKinds : []).filter(function(k) {
      return k && typeof k.id === "string" && k.id;
    }).map(function(k) {
      return { id: k.id, name: text(k.name) || k.id, hint: text(k.hint) };
    });
    snap.languages = (Array.isArray(raw.languages) ? raw.languages : []).filter(function(l) {
      return l && typeof l.code === "string" && l.code;
    }).map(function(l) {
      return { code: l.code, name: text(l.name) || l.code };
    });
    snap.shapeNames = {};
    (Array.isArray(raw.shapes) ? raw.shapes : []).forEach(function(s) {
      if (s && SHAPE_IDS.indexOf(s.id) >= 0) snap.shapeNames[s.id] = text(s.name) || SHAPE_NAMES[s.id];
    });
    snap.created = text(raw.created);
    snap.notice = text(raw.notice);
    snap.markdown = typeof raw.markdown === "string" ? raw.markdown : null;
    return snap;
  }
  window.mvResearchMapSet = function(documentId, snapshot) {
    if (String(documentId == null ? "" : documentId) !== String(window.mvDocumentId || "")) return;
    try {
      applySnapshot(snapshot);
    } catch (e) {
      reportError("mvResearchMapSet", e);
    }
  };
  function applySnapshot(raw) {
    const snap = normalise(raw);
    if (!snap.ok) {
      rm.snap = null;
      showProblem(snap.problem);
      if (rm.active) {
        window.leaveResearchMap();
        window.switchToSource();
      }
      return;
    }
    hideProblem();
    const firstOfMap = !rm.snap || rm.snap.id !== snap.id || !rm.mapKey;
    rm.snap = snap;
    if (firstOfMap) {
      rm.mapKey = "mvMap:" + (snap.id || "doc-" + rm.docId);
      const saved = loadSaved();
      rm.view = { x: 0, y: 0, scale: 1 };
      rm.viewReady = false;
      rm.panelWidth = PANEL_DEFAULT;
      rm.selected = null;
      rm.collapsed = /* @__PURE__ */ new Set();
      if (saved) {
        if (Array.isArray(saved.collapsed)) saved.collapsed.forEach(function(id) {
          if (typeof id === "string") rm.collapsed.add(id);
        });
        if (typeof saved.x === "number" && typeof saved.y === "number") {
          rm.view = { x: saved.x, y: saved.y, scale: clamp(Number(saved.scale) || 1, MIN_SCALE, MAX_SCALE) };
          rm.viewReady = true;
        }
        if (typeof saved.panel === "number") rm.panelWidth = clamp(saved.panel, PANEL_MIN, PANEL_MAX);
        if (typeof saved.selected === "string") rm.selected = saved.selected;
      }
    }
    Object.keys(rm.moves).forEach(function(id) {
      if (!snap.byId.has(id) || rm.moves[id].sent) delete rm.moves[id];
    });
    rm.boxes = {};
    if (rm.selected === null || rm.selected !== "" && !snap.byId.has(rm.selected)) {
      rm.selected = snap.byId.has(rm.fallbackSelect) ? rm.fallbackSelect : snap.nodes[0].id;
    }
    rm.fallbackSelect = "";
    if (snap.markdown !== null) {
      if ((rm.active || DOM.editor.value === rm.sourceBase) && DOM.editor.value !== snap.markdown) {
        DOM.editor.value = snap.markdown;
        state.markdown = snap.markdown;
      }
      if (DOM.editor.value === snap.markdown) rm.sourceBase = snap.markdown;
    }
    if (rm.active) {
      render();
      if (snap.created && snap.byId.has(snap.created)) {
        reveal(snap.created);
        A.select(snap.created);
        A.ensureVisible(snap.created);
      }
      if (snap.notice) toast(snap.notice);
    }
  }
  function showProblem(message) {
    el.problemText.textContent = message;
    el.problemText.title = message;
    el.problem.classList.add("visible");
  }
  function hideProblem() {
    el.problem.classList.remove("visible");
  }
  function toast(message) {
    el.toast.textContent = message;
    el.toast.hidden = false;
    clearTimeout(rm.toastTimer);
    rm.toastTimer = setTimeout(function() {
      el.toast.hidden = true;
    }, 4200);
  }
  function branchIndexes(nodes) {
    const index = /* @__PURE__ */ new Map();
    const rootId = nodes[0].id;
    const tops = nodes.filter(function(n) {
      return n.parent === rootId;
    });
    tops.forEach(function(n, i) {
      index.set(n.id, i);
    });
    const byId = rm.snap.byId;
    nodes.forEach(function(n) {
      let cur = n, guard = 0;
      while (cur && cur.id !== rootId && !index.has(cur.id) && guard++ < 1e3) cur = byId.get(cur.parent);
      index.set(n.id, cur && index.has(cur.id) ? index.get(cur.id) : 0);
    });
    index.set(rootId, 0);
    return index;
  }
  function render() {
    if (!rm.snap) return;
    const snap = rm.snap;
    el.loading.textContent = "";
    el.title.textContent = snap.title || snap.nodes[0].title;
    el.question.textContent = snap.question;
    el.title.title = snap.question || "";
    renderStatus();
    renderQueries();
    syncNodes();
    relayout();
    if (!rm.viewReady) A.initialView();
    A.applyView();
    A.applyPanelWidth();
    A.syncSelection();
    A.renderAI();
    A.fillPanel();
  }
  function branchOf(id) {
    return "var(--b" + (rm.branchIdx.get(id) || 0) % BRANCH_COLOURS + ")";
  }
  function branchHex(id) {
    const raw = getComputedStyle(el.root).getPropertyValue("--b" + (rm.branchIdx.get(id) || 0) % BRANCH_COLOURS).trim();
    return /^#[0-9a-f]{6}$/i.test(raw) ? raw.toLowerCase() : "#569cd6";
  }
  function childrenIndex() {
    const kids = /* @__PURE__ */ new Map();
    rm.snap.nodes.forEach(function(n) {
      if (!n.parent) return;
      if (!kids.has(n.parent)) kids.set(n.parent, []);
      kids.get(n.parent).push(n.id);
    });
    return kids;
  }
  function hiddenIds() {
    const hidden = /* @__PURE__ */ new Set();
    if (!rm.snap || !rm.collapsed.size) return hidden;
    const kids = childrenIndex(), rootId = rm.snap.nodes[0].id;
    rm.collapsed.forEach(function(id) {
      if (id === rootId || !rm.snap.byId.has(id)) return;
      const stack = (kids.get(id) || []).slice();
      while (stack.length) {
        const cur = stack.pop();
        if (hidden.has(cur)) continue;
        hidden.add(cur);
        (kids.get(cur) || []).forEach(function(k) {
          stack.push(k);
        });
      }
    });
    return hidden;
  }
  function descendantCounts() {
    const kids = childrenIndex(), counts = /* @__PURE__ */ new Map();
    const count = function(id, depth) {
      if (counts.has(id)) return counts.get(id);
      let total = 0;
      if (depth < 1e3) (kids.get(id) || []).forEach(function(k) {
        total += 1 + count(k, depth + 1);
      });
      counts.set(id, total);
      return total;
    };
    rm.snap.nodes.forEach(function(n) {
      count(n.id, 0);
    });
    return counts;
  }
  function toggleFold(id) {
    if (!rm.snap || !rm.snap.byId.has(id)) return;
    if (rm.collapsed.has(id)) rm.collapsed.delete(id);
    else rm.collapsed.add(id);
    A.closeMenu();
    const hidden = hiddenIds();
    if (rm.selected && hidden.has(rm.selected)) {
      rm.selected = id;
      A.fillPanel();
    }
    refreshTree();
    saveSoon();
  }
  function collapseAll() {
    if (!rm.snap) return;
    const kids = childrenIndex(), rootId = rm.snap.nodes[0].id;
    rm.collapsed = /* @__PURE__ */ new Set();
    rm.snap.nodes.forEach(function(n) {
      if (n.id !== rootId && kids.has(n.id)) rm.collapsed.add(n.id);
    });
    A.closeMenu();
    if (rm.selected && hiddenIds().has(rm.selected)) {
      let cur = nodeById(rm.selected);
      while (cur && hiddenIds().has(cur.id)) cur = nodeById(cur.parent);
      rm.selected = cur ? cur.id : rootId;
      A.fillPanel();
    }
    refreshTree();
    saveSoon();
  }
  function expandAll() {
    if (!rm.collapsed.size) return;
    rm.collapsed = /* @__PURE__ */ new Set();
    A.closeMenu();
    refreshTree();
    saveSoon();
  }
  function focusNode(id) {
    if (!rm.snap || !rm.snap.byId.has(id)) return;
    const kids = childrenIndex(), rootId = rm.snap.nodes[0].id, open = /* @__PURE__ */ new Set();
    for (let cur = nodeById(id), guard = 0; cur && guard++ < 1e3; cur = cur.parent ? nodeById(cur.parent) : null) open.add(cur.id);
    rm.collapsed = /* @__PURE__ */ new Set();
    rm.snap.nodes.forEach(function(n) {
      if (n.id !== rootId && kids.has(n.id) && !open.has(n.id)) rm.collapsed.add(n.id);
    });
    A.closeMenu();
    A.select(id);
    refreshTree();
    const p = rm.positions[id];
    if (p) {
      const size = A.viewSize();
      rm.view.x = size.w / 2 - p.x * rm.view.scale;
      rm.view.y = size.h / 2 - p.y * rm.view.scale;
      A.applyView();
    }
    saveSoon();
  }
  function reveal(id) {
    let changed = false, cur = nodeById(id), guard = 0;
    while (cur && cur.parent && guard++ < 1e3) {
      if (rm.collapsed.has(cur.parent)) {
        rm.collapsed.delete(cur.parent);
        changed = true;
      }
      cur = nodeById(cur.parent);
    }
    if (changed) refreshTree();
    return changed;
  }
  function refreshTree() {
    syncNodes();
    relayout();
    A.syncSelection();
  }
  function syncNodes() {
    const snap = rm.snap;
    rm.branchIdx = branchIndexes(snap.nodes);
    const rootId = snap.nodes[0].id;
    const present = /* @__PURE__ */ new Set();
    const counts = descendantCounts();
    snap.nodes.forEach(function(n) {
      present.add(n.id);
      const entry = rm.els.get(n.id) || makeNode(n.id);
      const colour = branchOf(n.id);
      const isRoot = n.id === rootId, isBranch = n.parent === rootId;
      const own = n.color;
      entry.wrap.classList.toggle("is-root", isRoot);
      entry.btn.className = "rm-node" + (isRoot ? " root" : isBranch ? " branch" : "") + (own ? " has-color" : "");
      const title = rm.pending[n.id] && rm.pending[n.id].fields.title || n.title;
      if (entry.label.textContent !== title) entry.label.textContent = title;
      syncVisual(entry, n, title);
      entry.badge.hidden = n.number == null;
      entry.badge.textContent = n.number == null ? "" : String(n.number);
      setGlyph(entry.glyph, n.icon);
      setThumb(entry, n.id, n.image);
      entry.lead.hidden = n.number == null && !n.icon && entry.thumb.hidden;
      const spoken = (n.number == null ? "" : "Number " + n.number + ". ") + (n.icon && NODE_ICONS[n.icon] ? n.icon + " icon. " : "") + (n.image ? "With a picture. " : "");
      entry.btn.setAttribute("aria-label", spoken + title + ". Select node; arrow keys move the node");
      entry.tri.setAttribute("aria-label", "Actions for node \u201C" + title + "\u201D");
      entry.wrap.style.setProperty("--branch", own || colour);
      entry.btn.style.setProperty("--tint", own ? mix(own, "#ffffff", 0.14) : "");
      entry.btn.style.setProperty("--tint-dark", own ? mix(own, "#252526", 0.22) : "");
      entry.btn.style.setProperty("--badge-ink", own ? readableOn(own) : "");
      entry.tri.hidden = false;
      const below = counts.get(n.id) || 0;
      const folded = below > 0 && !isRoot && rm.collapsed.has(n.id);
      entry.fold.hidden = below === 0 || isRoot;
      entry.fold.classList.toggle("folded", folded);
      entry.fold.setAttribute("aria-expanded", folded ? "false" : "true");
      entry.fold.title = folded ? "Show " + below + " hidden " + (below === 1 ? "node" : "nodes") : "Fold the " + (below === 1 ? "child node" : "child nodes") + " of this node";
      entry.fold.setAttribute("aria-label", (folded ? "Expand \u201C" : "Collapse \u201C") + title + "\u201D");
      entry.fold.textContent = "";
      if (folded) entry.fold.appendChild(document.createTextNode("+" + below));
      else entry.fold.appendChild(icon("chevron"));
    });
    const hidden = hiddenIds();
    rm.els.forEach(function(entry, id) {
      entry.wrap.hidden = hidden.has(id);
    });
    rm.els.forEach(function(entry, id) {
      if (present.has(id)) return;
      if (rm.menu === id) A.closeMenu();
      entry.wrap.remove();
      rm.els.delete(id);
    });
    rm.sizes = {};
    rm.els.forEach(function(entry, id) {
      if (hidden.has(id)) return;
      const node = nodeById(id);
      if (node) applyBox(entry, node, boxOf(node));
      const w = entry.btn.offsetWidth, hgt = entry.btn.offsetHeight;
      if (w > 0 && hgt > 0) rm.sizes[id] = { w, h: hgt };
    });
  }
  function syncVisual(entry, node, title) {
    const v = visualOf(node);
    entry.btn.classList.toggle("is-visual", !!v);
    entry.wrap.classList.toggle("visual", !!v);
    if (!v) {
      entry.vis.hidden = true;
      if (entry.vis._vk) {
        entry.vis.textContent = "";
        entry.vis._vk = "";
      }
      entry.btn.removeAttribute("title");
      return;
    }
    entry.vis.hidden = false;
    entry.btn.title = title;
    fillVisual(entry.vis, v, CARD_BOX, title, function() {
      remeasure(node.id);
    });
  }
  function expandVisual(id) {
    const entry = rm.els.get(id), node = nodeById(id), v = visualOf(node);
    if (!entry || !v) return;
    if (typeof openDiagramViewer !== "function") {
      toast("The full-screen viewer is not available.");
      return;
    }
    const holder = entry.vis;
    if (v.kind === "diagram") {
      const svg2 = holder.querySelector("svg");
      if (svg2) openDiagramViewer(svg2);
      else toast(holder.classList.contains("error") ? "This diagram could not be drawn." : "The diagram is still being drawn.");
      return;
    }
    const img = holder.querySelector("img");
    if (!img || !img.naturalWidth) {
      toast("The image is not loaded.");
      return;
    }
    const svg = document.createElementNS(NS, "svg");
    svg.setAttribute("viewBox", "0 0 " + img.naturalWidth + " " + img.naturalHeight);
    const image = document.createElementNS(NS, "image");
    image.setAttribute("href", img.currentSrc || img.src);
    image.setAttribute("width", String(img.naturalWidth));
    image.setAttribute("height", String(img.naturalHeight));
    svg.appendChild(image);
    openDiagramViewer(svg);
  }
  function boxOf(node) {
    const live = rm.resize && rm.resize.id === node.id ? rm.resize : rm.boxes[node.id];
    return live ? { width: live.width, height: live.height } : { width: node.width, height: node.height };
  }
  function applyBox(entry, node, box) {
    const wrap = entry.wrap, btn = entry.btn, body = entry.body;
    const shape = visualOf(node) ? "" : node.shape, fit = SHAPE_FIT[shape];
    SHAPE_IDS.forEach(function(id) {
      wrap.classList.toggle("shape-" + id, id !== "rounded" && id === shape);
    });
    if (shape === "diamond" && !entry.shapeSvg) {
      const svg = document.createElementNS(NS, "svg");
      svg.setAttribute("class", "rm-shape");
      svg.setAttribute("viewBox", "0 0 100 100");
      svg.setAttribute("preserveAspectRatio", "none");
      svg.setAttribute("aria-hidden", "true");
      const polygon = document.createElementNS(NS, "polygon");
      polygon.setAttribute("points", "50,1 99,50 50,99 1,50");
      svg.appendChild(polygon);
      btn.insertBefore(svg, btn.firstChild);
      entry.shapeSvg = svg;
    } else if (shape !== "diamond" && entry.shapeSvg) {
      entry.shapeSvg.remove();
      entry.shapeSvg = null;
    }
    const width = box.width, height = box.height;
    wrap.style.width = "";
    btn.style.minHeight = "";
    body.style.maxWidth = "";
    wrap.classList.toggle("has-w", width != null || !!fit);
    btn.classList.toggle("boxed", height != null || !!fit);
    entry.autoH = 0;
    if (!fit) {
      if (width != null) wrap.style.width = width + "px";
      if (height != null) {
        entry.autoH = btn.offsetHeight;
        btn.style.minHeight = height + "px";
      }
      return;
    }
    const textMax = width != null ? Math.max(24, Math.round(width * fit.k) - 2 * fit.padX) : fit.maxText;
    wrap.style.width = "max-content";
    body.style.maxWidth = textMax + "px";
    const tw = body.offsetWidth, th = body.offsetHeight;
    if (!tw || !th) {
      wrap.style.width = "";
      return;
    }
    const autoW = Math.max(fit.minW, Math.ceil(tw / fit.k) + 2 * fit.padX);
    entry.autoH = Math.max(fit.minH, Math.ceil(th / fit.k) + 2 * fit.padY);
    wrap.style.width = (width != null ? width : autoW) + "px";
    btn.style.minHeight = Math.max(entry.autoH, height || 0) + "px";
  }
  function remeasure(id) {
    const entry = rm.els.get(id), node = nodeById(id);
    if (!entry || !node) return;
    applyBox(entry, node, boxOf(node));
    const w = entry.btn.offsetWidth, hgt = entry.btn.offsetHeight;
    if (w > 0 && hgt > 0) rm.sizes[id] = { w, h: hgt };
    relayout();
  }
  function startResize(event, id, dir) {
    const entry = rm.els.get(id), node = nodeById(id);
    if (!entry || !node) return;
    event.preventDefault();
    const rect = entry.btn.getBoundingClientRect(), scale = rm.view.scale;
    const start = { x: event.clientX, y: event.clientY, w: rect.width / scale, h: rect.height / scale };
    const before = boxOf(node);
    const horizontal = dir.indexOf("e") >= 0 || dir.indexOf("w") >= 0, vertical = dir.indexOf("n") >= 0 || dir.indexOf("s") >= 0;
    const sx = dir.indexOf("w") >= 0 ? -1 : 1, sy = dir.indexOf("n") >= 0 ? -1 : 1;
    let active = false, cancelled = false;
    try {
      event.target.setPointerCapture(event.pointerId);
    } catch (e) {
    }
    const onKey = function(e) {
      if (e.key !== "Escape" || !active) return;
      cancelled = true;
      e.preventDefault();
      finish(null);
    };
    const stop = A.listen(function(e) {
      const dx = e.clientX - start.x, dy = e.clientY - start.y;
      if (!active) {
        if (Math.hypot(dx, dy) <= 3) return;
        active = true;
        A.closeMenu();
      }
      rm.resize = {
        id,
        width: horizontal ? clamp(Math.round(start.w + 2 * sx * dx / scale), LIMITS.width[0], LIMITS.width[1]) : before.width,
        height: vertical ? clamp(Math.round(start.h + 2 * sy * dy / scale), LIMITS.height[0], LIMITS.height[1]) : before.height
      };
      remeasure(id);
      const size = rm.sizes[id];
      el.readout.hidden = false;
      el.readout.textContent = size ? "w " + Math.round(size.w) + " \xB7 h " + Math.round(size.h) : "";
    }, function(e) {
      finish(e);
    });
    window.addEventListener("keydown", onKey, true);
    function finish(e) {
      stop();
      window.removeEventListener("keydown", onKey, true);
      el.readout.hidden = true;
      if (!active) return;
      rm.lastDragEnd = now();
      const live = rm.resize;
      rm.resize = null;
      if (cancelled || !live || e && e.type === "pointercancel") {
        remeasure(id);
        return;
      }
      const fields = {};
      if (horizontal) fields.width = live.width;
      if (vertical) fields.height = entry.autoH && live.height <= entry.autoH ? null : live.height;
      rm.boxes[id] = {
        width: horizontal ? fields.width : before.width,
        height: vertical ? fields.height : before.height
      };
      remeasure(id);
      send("update", Object.assign({ id }, fields));
    }
  }
  function makeNode(id) {
    const badge = h("span", { class: "rm-badge", hidden: true });
    const glyph = h("span", { class: "rm-glyph", hidden: true, "aria-hidden": "true" });
    const thumb = h("img", { class: "rm-thumb", alt: "", hidden: true, draggable: "false" });
    const lead = h("span", { class: "rm-lead", hidden: true }, badge, glyph, thumb);
    const label = h("span", { class: "rm-label" });
    const visual = h("span", { class: "rm-vis", hidden: true });
    const body = h("span", { class: "rm-body" }, lead, label, visual);
    const btn = h("button", { class: "rm-node", type: "button", "aria-pressed": "false" }, body);
    const tri = h("button", { class: "rm-tri", type: "button", title: "Node menu: AI actions, add, connect, arrange, delete", "aria-haspopup": "true", "aria-expanded": "false" }, "\u22EF");
    const fold = h("button", { class: "rm-fold", type: "button", hidden: true, "aria-expanded": "true" });
    const arrow = h("button", { class: "rm-arrow", type: "button", tabindex: "-1", title: "Drag onto another node to make it a child of this node", "aria-label": "Drag onto another node to make it a child of this node" }, "\u2192");
    const handles = HANDLES.map(function(dir) {
      const handle = h("span", { class: "rm-handle", "data-h": dir, "aria-hidden": "true", hidden: true });
      handle.addEventListener("dblclick", function(event) {
        event.stopPropagation();
        const node = nodeById(id);
        if (!node) return;
        const current = boxOf(node);
        if (current.width == null && current.height == null) return;
        rm.boxes[id] = { width: null, height: null };
        remeasure(id);
        send("update", { id, width: null, height: null });
      });
      return handle;
    });
    const wrap = h("div", { class: "rm-node-wrap", "data-id": id }, btn, tri, fold, arrow, handles);
    const entry = { wrap, btn, body, tri, fold, arrow, lead, badge, glyph, thumb, label, vis: visual, handles, shapeSvg: null, autoH: 0 };
    btn.addEventListener("dblclick", function() {
      const node = nodeById(id);
      if (node && visualOf(node)) expandVisual(id);
    });
    fold.addEventListener("click", function(event) {
      event.stopPropagation();
      toggleFold(id);
    });
    btn.addEventListener("click", function() {
      if (now() - rm.lastDragEnd < 60) return;
      A.select(id);
    });
    tri.addEventListener("click", function(event) {
      event.stopPropagation();
      if (rm.menu === id) A.closeMenu();
      else A.openMenu(id);
    });
    el.world.appendChild(wrap);
    rm.els.set(id, entry);
    return entry;
  }
  function layoutNodes() {
    const hidden = hiddenIds();
    return rm.snap.nodes.filter(function(n) {
      return !hidden.has(n.id);
    }).map(function(n) {
      const move = rm.drag && rm.drag.id === n.id ? rm.drag : rm.moves[n.id];
      return move ? Object.assign({}, n, { x: move.x, y: move.y }) : n;
    });
  }
  function relayout() {
    if (!rm.snap) return;
    const result = Layout.compute({
      nodes: layoutNodes(),
      layouts: rm.snap.layouts,
      size: function(node) {
        return rm.sizes[node.id] || Layout.estimateSize(node, node.id === rm.snap.nodes[0].id);
      }
    });
    rm.positions = result.positions;
    rm.els.forEach(function(entry, id) {
      const p = rm.positions[id];
      if (!p) return;
      entry.wrap.style.left = p.x + "px";
      entry.wrap.style.top = p.y + "px";
      const own = nodeById(id), parentAt = own && own.parent ? rm.positions[own.parent] : null;
      entry.wrap.classList.toggle("arrow-left", !!parentAt && p.x < parentAt.x - 1);
    });
    drawLines();
  }
  function curve(a, b) {
    const dx = b.x - a.x, dy = b.y - a.y;
    if (Math.abs(dx) >= Math.abs(dy)) {
      const mid2 = (a.x + b.x) / 2;
      return "M " + a.x + " " + a.y + " C " + mid2 + " " + a.y + ", " + mid2 + " " + b.y + ", " + b.x + " " + b.y;
    }
    const mid = (a.y + b.y) / 2;
    return "M " + a.x + " " + a.y + " C " + a.x + " " + mid + ", " + b.x + " " + mid + ", " + b.x + " " + b.y;
  }
  function addPath(d, color, dashed, kind) {
    const path = document.createElementNS(NS, "path");
    path.setAttribute("d", d);
    path.setAttribute("fill", "none");
    path.style.stroke = color;
    path.setAttribute("stroke-width", dashed ? "1.5" : "2");
    path.setAttribute("stroke-linecap", "round");
    path.setAttribute("data-line", kind);
    if (dashed) path.setAttribute("stroke-dasharray", "6 6");
    el.svg.appendChild(path);
    return path;
  }
  function drawLines() {
    while (el.svg.firstChild) el.svg.removeChild(el.svg.firstChild);
    if (el.linkX && el.linkX.parentNode) el.linkX.parentNode.removeChild(el.linkX);
    const snap = rm.snap;
    snap.nodes.forEach(function(n) {
      const a = rm.positions[n.parent], b = rm.positions[n.id];
      if (a && b) addPath(curve(a, b), n.color || branchOf(n.id), false, "tree");
    });
    let chosen = null;
    snap.links.forEach(function(l) {
      const a = rm.positions[l.from], b = rm.positions[l.to];
      if (!a || !b) return;
      const picked = rm.selLink === l.from + "|" + l.to;
      const line = addPath(curve(a, b), picked ? "var(--accent-primary)" : "var(--rm-muted)", true, "link");
      if (picked) {
        line.setAttribute("stroke-width", "2.5");
        chosen = { l, a, b };
      }
      const hit = addPath(curve(a, b), "transparent", false, "link-hit");
      hit.setAttribute("data-from", l.from);
      hit.setAttribute("data-to", l.to);
    });
    if (rm.selLink && !chosen) rm.selLink = "";
    if (chosen) {
      el.linkX = h("button", {
        class: "rm-linkx",
        type: "button",
        title: "Remove this connection",
        "aria-label": "Remove this connection",
        "data-from": chosen.l.from,
        "data-to": chosen.l.to,
        style: "left:" + (chosen.a.x + chosen.b.x) / 2 + "px;top:" + (chosen.a.y + chosen.b.y) / 2 + "px;",
        onClick: function(event) {
          event.stopPropagation();
          removeSelectedLink();
        }
      }, icon("close"));
      el.world.appendChild(el.linkX);
    }
    if (rm.connect) {
      const from = rm.positions[rm.connect.from];
      if (from) addPath("M " + from.x + " " + from.y + " L " + rm.connect.x + " " + rm.connect.y, "var(--accent-primary)", true, "connect");
    }
  }
  function selectLink(from, to) {
    if (rm.selected) A.select("");
    rm.selLink = from + "|" + to;
    A.closeMenu();
    drawLines();
  }
  function clearLink() {
    if (!rm.selLink) return;
    rm.selLink = "";
    drawLines();
  }
  function removeSelectedLink() {
    const parts = rm.selLink.split("|");
    if (parts.length !== 2) return;
    rm.selLink = "";
    send("unlink", { from: parts[0], to: parts[1] });
    drawLines();
  }
  function elapsedText(job) {
    if (!job || !job.startedAt) return "";
    const total = Math.max(0, Math.floor(Date.now() / 1e3 - job.startedAt));
    return Math.floor(total / 60) + ":" + String(total % 60).padStart(2, "0");
  }
  function renderStatus() {
    const snap = rm.snap, box = el.status;
    box.textContent = "";
    box.classList.remove("warn");
    el.elapsed = null;
    if (snap.job || snap.status === "researching") {
      const job = snap.job;
      const parts = job ? [job.label || "Researching", job.step].filter(Boolean).join(" \xB7 ") : "Researching\u2026";
      el.elapsed = h("span", { class: "rm-elapsed" }, job ? elapsedText(job) : "");
      box.appendChild(h("span", { class: "rm-spin", "aria-hidden": "true" }));
      box.appendChild(h("span", { class: "rm-status-text", title: parts }, parts));
      box.appendChild(el.elapsed);
      box.appendChild(h("button", { class: "rm-chip-btn", type: "button", "data-act": "stop", title: "Stop the research" }, icon("stop"), "Stop"));
      box.lastChild.addEventListener("click", function() {
        send("cancel");
      });
      box.hidden = false;
      box.setAttribute("data-state", "researching");
      startTicker();
      return;
    }
    stopTicker();
    if (snap.status === "incomplete") {
      const reason = snap.incomplete || "The research stopped early.";
      box.classList.add("warn");
      box.appendChild(h("span", { class: "rm-status-text", title: reason }, "Incomplete \xB7 " + reason));
      box.appendChild(h("button", { class: "rm-chip-btn", type: "button", "data-act": "continue", title: "Continue the research" }, icon("play"), "Continue"));
      box.lastChild.addEventListener("click", function() {
        send("continue");
      });
      box.hidden = false;
      box.setAttribute("data-state", "incomplete");
      return;
    }
    box.hidden = true;
    box.removeAttribute("data-state");
  }
  function startTicker() {
    if (rm.ticker) return;
    rm.ticker = setInterval(function() {
      if (!rm.active || !rm.snap || !rm.snap.job || !el.elapsed) return;
      el.elapsed.textContent = elapsedText(rm.snap.job);
    }, 1e3);
  }
  function stopTicker() {
    if (rm.ticker) {
      clearInterval(rm.ticker);
      rm.ticker = 0;
    }
  }
  function renderQueries() {
    const queries = rm.snap.webQueries;
    el.queriesBtn.hidden = queries.length === 0;
    el.queryCount.textContent = String(queries.length);
    el.popover.textContent = "";
    el.popover.appendChild(h("h3", null, "Web searches (" + queries.length + ")"));
    el.popover.appendChild(h("ol", null, queries.map(function(q) {
      return h("li", null, q);
    })));
    if (!queries.length) closeQueries();
  }
  function toggleQueries() {
    if (rm.queriesOpen) closeQueries();
    else {
      A.closeExport();
      rm.queriesOpen = true;
      el.popover.hidden = false;
    }
  }
  function closeQueries() {
    rm.queriesOpen = false;
    el.popover.hidden = true;
  }
})(window.MVResearchMapView);
;
(function(A) {
  "use strict";
  if (!A.ready) return;
  const {
    MAX_SCALE,
    MIN_SCALE,
    PANEL_MAX,
    PANEL_MIN,
    clamp,
    clearLink,
    closeQueries,
    drawLines,
    el,
    nodeById,
    now,
    queueMove,
    relayout,
    removeSelectedLink,
    rm,
    saveSoon,
    selectLink,
    send,
    startResize,
    toast
  } = A;
  Object.assign(A, {
    applyPanelWidth,
    applyView,
    centreView,
    ensureVisible,
    initialView,
    listen,
    viewSize,
    zoomAtCentre
  });
  function viewSize() {
    return { w: el.viewport.clientWidth || 800, h: el.viewport.clientHeight || 600 };
  }
  function applyView() {
    el.world.style.transform = "translate(" + rm.view.x + "px," + rm.view.y + "px) scale(" + rm.view.scale + ")";
    el.world.style.setProperty("--rm-inv", String(Math.round(100 / rm.view.scale) / 100));
    el.zoom.textContent = Math.round(rm.view.scale * 100) + "%";
  }
  function initialView() {
    const size = viewSize(), root = rm.positions[rm.snap.nodes[0].id] || { x: 0, y: 0 };
    rm.view = { x: size.w / 2 - root.x, y: size.h / 2 - root.y, scale: 1 };
    rm.viewReady = true;
  }
  function centreView() {
    const size = viewSize(), root = rm.positions[rm.snap.nodes[0].id] || { x: 0, y: 0 };
    rm.view = { x: size.w / 2 - root.x, y: size.h / 2 - root.y, scale: 1 };
    applyView();
    saveSoon();
  }
  function zoomAt(next, cx, cy) {
    A.closeMenu();
    const old = rm.view.scale, scale = clamp(next, MIN_SCALE, MAX_SCALE);
    rm.view = { x: cx - (cx - rm.view.x) * scale / old, y: cy - (cy - rm.view.y) * scale / old, scale };
    applyView();
    saveSoon();
  }
  function zoomAtCentre(next) {
    const s = viewSize();
    zoomAt(next, s.w / 2, s.h / 2);
  }
  function ensureVisible(id) {
    const p = rm.positions[id];
    if (!p) return;
    const size = viewSize(), sx = p.x * rm.view.scale + rm.view.x, sy = p.y * rm.view.scale + rm.view.y, margin = 80;
    if (sx > margin && sx < size.w - margin && sy > margin && sy < size.h - margin) return;
    rm.view.x = size.w / 2 - p.x * rm.view.scale;
    rm.view.y = size.h / 2 - p.y * rm.view.scale;
    applyView();
    saveSoon();
  }
  el.viewport.addEventListener("wheel", function(event) {
    event.preventDefault();
    let delta = event.deltaY || event.deltaX;
    if (event.deltaMode === 1) delta *= 16;
    else if (event.deltaMode === 2) delta *= 100;
    if (!delta) return;
    const rect = el.viewport.getBoundingClientRect();
    zoomAt(rm.view.scale * Math.pow(1.1, clamp(-delta / 12, -1, 1)), event.clientX - rect.left, event.clientY - rect.top);
  }, { passive: false });
  el.viewport.addEventListener("pointerdown", function(event) {
    if (event.button !== 0) return;
    const handle = event.target.closest(".rm-handle");
    if (handle) {
      startResize(event, handle.parentNode.getAttribute("data-id"), handle.getAttribute("data-h"));
      return;
    }
    const arrow = event.target.closest(".rm-arrow");
    if (arrow) {
      startConnect(event, arrow.parentNode.getAttribute("data-id"));
      return;
    }
    const hit = event.target.closest('[data-line="link-hit"]');
    if (hit) {
      event.preventDefault();
      selectLink(hit.getAttribute("data-from"), hit.getAttribute("data-to"));
      return;
    }
    if (event.target.closest(".rm-tri, .rm-fold, .rm-actions, .rm-linkx")) return;
    const nodeEl = event.target.closest(".rm-node");
    if (nodeEl) startNodeDrag(event, nodeEl.parentNode.getAttribute("data-id"));
    else startPan(event);
  });
  function listen(move, end) {
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", end);
    window.addEventListener("pointercancel", end);
    return function stop() {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", end);
      window.removeEventListener("pointercancel", end);
    };
  }
  function startPan(event) {
    const start = { x: event.clientX, y: event.clientY, vx: rm.view.x, vy: rm.view.y };
    let moved = false;
    try {
      el.viewport.setPointerCapture(event.pointerId);
    } catch (e) {
    }
    const stop = listen(function(e) {
      const dx = e.clientX - start.x, dy = e.clientY - start.y;
      if (!moved && Math.hypot(dx, dy) <= 3) return;
      moved = true;
      A.closeMenu();
      el.viewport.classList.add("is-panning");
      rm.view.x = start.vx + dx;
      rm.view.y = start.vy + dy;
      applyView();
    }, function() {
      stop();
      el.viewport.classList.remove("is-panning");
      if (moved) saveSoon();
      else {
        A.closeMenu();
        closeQueries();
        A.select("");
        clearLink();
      }
    });
  }
  function connectProblem(from, to) {
    if (!rm.snap || !nodeById(from) || !nodeById(to)) return "That node no longer exists.";
    if (to === rm.snap.nodes[0].id) return "The root node cannot be moved.";
    if (to === from) return "A node cannot become its own child.";
    for (let cur = nodeById(from), guard = 0; cur && guard < 1e4; cur = cur.parent ? nodeById(cur.parent) : null, guard++) {
      if (cur.id === to) return "A node cannot be moved under one of its own descendants.";
    }
    if (nodeById(to).parent === from) return "\u201C" + nodeById(from).title + "\u201D is already the parent of this node.";
    return "";
  }
  function startConnect(event, from) {
    if (!rm.positions[from]) return;
    event.preventDefault();
    A.closeMenu();
    const rect = el.viewport.getBoundingClientRect();
    const world = function(e) {
      return { x: (e.clientX - rect.left - rm.view.x) / rm.view.scale, y: (e.clientY - rect.top - rm.view.y) / rm.view.scale };
    };
    const start = { x: event.clientX, y: event.clientY };
    let active = false, target = "";
    const mark = function(id) {
      if (id === target) return;
      const old = target && rm.els.get(target);
      if (old) old.wrap.classList.remove("connect-ok", "connect-no");
      target = id;
      const entry = id && rm.els.get(id);
      if (entry) entry.wrap.classList.add(connectProblem(from, id) ? "connect-no" : "connect-ok");
    };
    const finish = function() {
      stop();
      window.removeEventListener("keydown", onEsc, true);
      mark("");
      const entry = rm.els.get(from);
      if (entry) entry.wrap.classList.remove("connect-from");
      el.viewport.classList.remove("is-connecting");
      rm.connect = null;
      rm.lastDragEnd = now();
      drawLines();
    };
    const onEsc = function(e) {
      if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        finish();
      }
    };
    window.addEventListener("keydown", onEsc, true);
    const stop = listen(function(e) {
      if (!active) {
        if (Math.hypot(e.clientX - start.x, e.clientY - start.y) <= 3) return;
        active = true;
        el.viewport.classList.add("is-connecting");
        const entry = rm.els.get(from);
        if (entry) entry.wrap.classList.add("connect-from");
      }
      const at = world(e);
      rm.connect = { from, x: at.x, y: at.y };
      const under = document.elementFromPoint(e.clientX, e.clientY) || e.target;
      const over = under && under.closest ? under.closest(".rm-node-wrap") : null;
      mark(over ? over.getAttribute("data-id") : "");
      drawLines();
    }, function(e) {
      const chosen = e.type === "pointercancel" ? "" : target;
      const wasActive = active;
      finish();
      if (!wasActive || !chosen) return;
      const problem = connectProblem(from, chosen);
      if (problem) {
        toast(problem);
        return;
      }
      rm.collapsed.delete(from);
      saveSoon();
      A.select(chosen);
      send("move", { id: chosen, parent: from });
    });
  }
  function startNodeDrag(event, id) {
    const origin = rm.positions[id];
    if (!origin) return;
    const start = { x: event.clientX, y: event.clientY };
    let dragging = false;
    try {
      event.target.setPointerCapture(event.pointerId);
    } catch (e) {
    }
    const stop = listen(function(e) {
      const dx = e.clientX - start.x, dy = e.clientY - start.y;
      if (!dragging) {
        if (Math.hypot(dx, dy) <= 3) return;
        dragging = true;
        A.closeMenu();
      }
      rm.drag = { id, x: origin.x + dx / rm.view.scale, y: origin.y + dy / rm.view.scale };
      relayout();
      el.readout.hidden = false;
      el.readout.textContent = "x " + Math.round(rm.drag.x) + " \xB7 y " + Math.round(rm.drag.y);
    }, function(e) {
      stop();
      el.readout.hidden = true;
      if (!dragging) return;
      rm.lastDragEnd = now();
      const drag = rm.drag;
      rm.drag = null;
      if (e.type === "pointercancel" || !drag) {
        relayout();
        return;
      }
      commitMove(id, Math.round(drag.x), Math.round(drag.y));
    });
  }
  function commitMove(id, x, y) {
    rm.moves[id] = { x, y, sent: true };
    relayout();
    send("moveVisual", { id, x, y });
  }
  document.addEventListener("keydown", function(event) {
    if (!rm.active || rm.dialog || !rm.selLink || event.metaKey || event.ctrlKey || event.altKey || event.defaultPrevented) return;
    const target = event.target;
    if (target && target.closest && target.closest("input, textarea, select, [contenteditable], .rm-divider, .rm-popover, .rm-layouts, .rm-modal")) return;
    if (event.key === "Delete" || event.key === "Backspace") {
      event.preventDefault();
      removeSelectedLink();
    } else if (event.key === "Escape") {
      event.preventDefault();
      clearLink();
    }
  });
  document.addEventListener("keydown", function(event) {
    if (!rm.active || rm.dialog || !rm.selected || event.metaKey || event.ctrlKey || event.altKey || event.defaultPrevented) return;
    if (event.key.indexOf("Arrow") !== 0) return;
    const target = event.target;
    if (target && target.closest && target.closest("input, textarea, select, [contenteditable], .rm-divider, .rm-popover, .rm-layouts, .rm-modal")) return;
    onNodeKey(event, rm.selected);
  });
  function onNodeKey(event, id) {
    const step = event.shiftKey ? 40 : 10;
    const dx = event.key === "ArrowLeft" ? -step : event.key === "ArrowRight" ? step : 0;
    const dy = event.key === "ArrowUp" ? -step : event.key === "ArrowDown" ? step : 0;
    if (!dx && !dy) return;
    event.preventDefault();
    const p = rm.positions[id];
    if (!p) return;
    const x = Math.round(p.x + dx), y = Math.round(p.y + dy);
    rm.moves[id] = { x, y, sent: false };
    relayout();
    queueMove(id, x, y);
  }
  function maxPanel() {
    return Math.min(PANEL_MAX, Math.max(PANEL_MIN, el.workspace.clientWidth * 0.6));
  }
  function setPanelWidth(value) {
    rm.panelWidth = clamp(value, PANEL_MIN, maxPanel());
    applyPanelWidth();
    saveSoon();
  }
  function applyPanelWidth() {
    const width = clamp(rm.panelWidth, PANEL_MIN, maxPanel());
    el.workspace.style.setProperty("--rm-panel-width", width + "px");
    el.divider.setAttribute("aria-valuenow", String(Math.round(width)));
  }
  el.divider.addEventListener("keydown", function(event) {
    if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
    event.preventDefault();
    setPanelWidth(rm.panelWidth + (event.key === "ArrowLeft" ? 20 : -20));
  });
  el.divider.addEventListener("pointerdown", function(event) {
    if (event.button !== 0) return;
    const start = event.clientX, initial = rm.panelWidth;
    try {
      el.divider.setPointerCapture(event.pointerId);
    } catch (e) {
    }
    const stop = listen(function(e) {
      setPanelWidth(initial + start - e.clientX);
    }, function() {
      stop();
    });
  });
  window.addEventListener("resize", function() {
    if (rm.active) applyPanelWidth();
  });
})(window.MVResearchMapView);
;
(function(A) {
  "use strict";
  if (!A.ready) return;
  const {
    AI_ACTIONS,
    LIMITS,
    Layout,
    MAX_TITLE,
    NODE_ICONS,
    NODE_ICON_IDS,
    PANEL_BOX,
    SHAPE_IDS,
    SHAPE_NAMES,
    SIZE_PRESETS,
    VISUAL_KINDS,
    boxOf,
    branchHex,
    clamp,
    clearLink,
    closeQueries,
    diagramSourceOf,
    el,
    ensureVisible,
    fillVisual,
    fitTitle,
    flushAll,
    focusNode,
    h,
    icon,
    imageOf,
    imageURL,
    nodeById,
    queueUpdate,
    reveal,
    rm,
    saveSoon,
    send,
    setGlyph,
    toast,
    visualOf
  } = A;
  Object.assign(A, {
    closeDialog,
    closeExport,
    closeMenu,
    currentDescription,
    exportDialog,
    fillPanel,
    iconDialog,
    openMenu,
    pictureDialog,
    renderAI,
    runAI,
    select,
    syncSelection,
    toggleDrawList,
    toggleExport,
    translateDialog
  });
  function select(id) {
    if (id) clearLink();
    if (rm.selected === id) return;
    flushAll();
    closeMenu();
    rm.selected = id;
    syncSelection();
    fillPanel();
    saveSoon();
  }
  function syncSelection() {
    rm.els.forEach(function(entry, id) {
      const chosen = id === rm.selected;
      entry.btn.setAttribute("aria-pressed", chosen ? "true" : "false");
      entry.wrap.classList.toggle("selected", chosen);
      entry.handles.forEach(function(handle) {
        handle.hidden = !chosen;
      });
    });
  }
  function currentDescription(id) {
    const pending = rm.pending[id];
    if (pending && Object.prototype.hasOwnProperty.call(pending.fields, "description")) return pending.fields.description;
    const node = nodeById(id);
    return node ? node.description : "";
  }
  function syncVisualPanel(node) {
    const kind = node.visual || "text";
    VISUAL_KINDS.forEach(function(k) {
      el.visualBtns[k[0]].setAttribute("aria-pressed", k[0] === kind ? "true" : "false");
    });
    el.visualPane.hidden = !node.visual;
    const v = visualOf(node);
    el.shapeRow.hidden = !!v;
    if (!node.visual) {
      el.visualPreview._vk = "";
      return;
    }
    const diagram = node.visual === "diagram";
    el.visualSource.hidden = !diagram;
    el.imageInput.hidden = diagram;
    if (diagram) setField(el.visualSource, diagramSourceOf(node.description) || "", node.id, "description");
    else setField(el.imageInput, (imageOf(node.description) || {}).src || "", node.id, "description");
    el.visualPreview.hidden = !v;
    el.visualExpand.hidden = !v;
    if (v) fillVisual(el.visualPreview, v, PANEL_BOX, node.title, null);
    else el.visualPreview._vk = "";
  }
  function setField(field, value, id, key) {
    if (field.value === value) return;
    if (document.activeElement === field) return;
    if (rm.pending[id] && Object.prototype.hasOwnProperty.call(rm.pending[id].fields, key)) return;
    field.value = value;
  }
  function fillPanel(forceNumber) {
    const node = nodeById(rm.selected);
    el.empty.hidden = !!node;
    el.body.hidden = !node;
    if (!node) {
      rm.panelFor = null;
      return;
    }
    const fresh = rm.panelFor !== node.id;
    rm.panelFor = node.id;
    if (fresh) {
      el.titleInput.value = node.title;
      el.titleError.textContent = "";
      el.desc.value = node.description;
      el.tagInput.value = "";
    } else {
      if (!el.titleError.textContent) setField(el.titleInput, node.title, node.id, "title");
      setField(el.desc, node.description, node.id, "description");
    }
    syncVisualPanel(node);
    const shownColor = node.color || branchHex(node.id);
    if (document.activeElement !== el.color) el.color.value = shownColor;
    el.colorClear.hidden = !node.color;
    setGlyph(el.iconGlyph, node.icon);
    el.iconText.textContent = node.icon ? NODE_ICONS[node.icon] ? node.icon.charAt(0).toUpperCase() + node.icon.slice(1) : "Emoji" : "None";
    el.iconClear.hidden = !node.icon;
    const pictureURL = node.image ? imageURL(node.image) : null;
    el.imageThumb.hidden = !pictureURL;
    if (pictureURL && el.imageThumb._key !== pictureURL) {
      el.imageThumb._key = pictureURL;
      el.imageThumb.src = pictureURL;
    }
    el.imageText.textContent = node.image ? node.image.split("/").pop().slice(0, 28) : "None";
    el.imageClear.hidden = !node.image;
    if (forceNumber === true || document.activeElement !== el.numberInput) el.numberInput.value = node.number == null ? "" : String(node.number);
    const look = boxOf(node), shown = node.shape || "rounded";
    SHAPE_IDS.forEach(function(id) {
      const name = rm.snap.shapeNames && rm.snap.shapeNames[id] || SHAPE_NAMES[id];
      const button = el.shapeBtns[id];
      button.setAttribute("aria-pressed", id === shown ? "true" : "false");
      button.title = name;
      button.setAttribute("aria-label", name + " shape");
    });
    el.sizeBtns.auto.setAttribute("aria-pressed", look.width == null && look.height == null ? "true" : "false");
    SIZE_PRESETS.forEach(function(p) {
      el.sizeBtns[p.id].setAttribute("aria-pressed", look.width === p.w && look.height === p.h ? "true" : "false");
    });
    [["width", el.widthInput], ["height", el.heightInput]].forEach(function(pair) {
      const key = pair[0], input = pair[1];
      input.min = String(LIMITS[key][0]);
      input.max = String(LIMITS[key][1]);
      if (forceNumber === true || document.activeElement !== input) input.value = look[key] == null ? "" : String(look[key]);
    });
    Array.prototype.slice.call(el.tags.querySelectorAll(".rm-tag")).forEach(function(chip) {
      chip.remove();
    });
    node.tags.forEach(function(tag) {
      const chip = h("span", { class: "rm-tag", "data-tag": tag }, tag, h("button", { type: "button", "aria-label": "Remove tag \u201C" + tag + "\u201D", onClick: function() {
        queueUpdate(node.id, { tags: node.tags.filter(function(t) {
          return t !== tag;
        }) }, true);
      } }, "\xD7"));
      el.tags.insertBefore(chip, el.tagInput);
    });
    el.evList.textContent = "";
    node.evidence.forEach(function(ev) {
      const row = h(
        "li",
        { class: "rm-ev-row" },
        h("span", { class: "rm-ev-chip", "data-label": ev.label }, ev.label || "Finding"),
        h("span", { class: "rm-ev-text" }, ev.text)
      );
      if (ev.source) {
        row.appendChild(h("button", { class: "rm-ev-source", type: "button", title: "Open " + ev.source, "data-source": ev.source, onClick: function(event) {
          event.preventDefault();
          event.stopPropagation();
          send("open", { source: ev.source });
        } }, ev.source));
      }
      el.evList.appendChild(row);
    });
    renderAI();
    el.evHeading.textContent = "Evidence (" + node.evidence.length + ")";
    el.evSection.hidden = node.evidence.length === 0;
    el.connList.textContent = "";
    const mine = rm.snap.links.filter(function(l) {
      return l.from === node.id || l.to === node.id;
    });
    mine.forEach(function(l) {
      const otherId = l.from === node.id ? l.to : l.from, other = nodeById(otherId);
      const name = other ? other.title : otherId;
      el.connList.appendChild(h(
        "li",
        { class: "rm-conn-row", "data-from": l.from, "data-to": l.to },
        h("button", { class: "rm-conn-name", type: "button", title: "Select this node", onClick: function() {
          reveal(otherId);
          select(otherId);
          ensureVisible(otherId);
        } }, "\u2194 " + name),
        h("button", { class: "rm-x", type: "button", title: "Remove this connection", "aria-label": "Remove the connection to \u201C" + name + "\u201D", onClick: function() {
          send("unlink", { from: l.from, to: l.to });
        } }, icon("close"))
      ));
    });
    el.connHeading.textContent = "Connections (" + mine.length + ")";
    el.connSection.hidden = mine.length === 0;
    fitTitle();
    fitTitle();
  }
  function descendantIds(id) {
    const ids = [id];
    for (let i = 0; i < ids.length; i++) rm.snap.nodes.forEach(function(n) {
      if (n.parent === ids[i] && ids.indexOf(n.id) < 0) ids.push(n.id);
    });
    return ids;
  }
  function closeMenu() {
    if (rm.menu == null && !rm.menuEl) return;
    const entry = rm.els.get(rm.menu);
    if (entry) {
      entry.wrap.classList.remove("menu-open");
      entry.tri.setAttribute("aria-expanded", "false");
    }
    if (rm.menuEl) {
      rm.menuEl.remove();
      rm.menuEl = null;
    }
    rm.menu = null;
  }
  function placeMenu(bar, entry) {
    const host = el.left.getBoundingClientRect(), anchor = entry.tri.getBoundingClientRect();
    const width = bar.offsetWidth, height = bar.offsetHeight;
    let left = anchor.right - host.left - width, top = anchor.bottom - host.top + 4;
    left = clamp(left, 4, Math.max(4, host.width - width - 4));
    if (top + height > host.height - 4) top = Math.max(4, host.height - height - 4);
    bar.style.left = left + "px";
    bar.style.top = top + "px";
  }
  function aiBusy() {
    return !!(rm.snap && (rm.snap.job || rm.snap.status === "researching"));
  }
  const BUSY_HINT = "An AI job is already working on this map; stop it or wait for it first.";
  function openMenu(id) {
    closeMenu();
    closeExport();
    const entry = rm.els.get(id), node = nodeById(id);
    if (!entry || !node) return;
    const snap = rm.snap, isRoot = id === snap.nodes[0].id, busy = aiBusy();
    const dialogs = { develop: true, correct: true };
    const bar = h("div", { class: "rm-actions", role: "menu", "aria-label": "Actions for node \u201C" + node.title + "\u201D" });
    const addItem = function(item) {
      const button = h("button", {
        class: "rm-item" + (item.ai ? " ai" : "") + (item.danger ? " danger" : ""),
        type: "button",
        role: "menuitem",
        "data-act": item.act,
        title: item.off && item.offHint ? item.offHint : item.hint || item.label,
        "aria-label": item.label,
        disabled: !!item.off
      }, icon(item.icon), h("span", null, item.label));
      if (item.more) button.appendChild(h("span", { class: "rm-more", "aria-hidden": "true" }, "\u25BE"));
      button.addEventListener("click", function(event) {
        event.stopPropagation();
        if (item.act === "arrange") {
          toggleLayouts(bar, node, button, entry);
          return;
        }
        if (item.act === "draw") {
          toggleDrawMenu(bar, node, button, entry);
          return;
        }
        closeMenu();
        item.run();
      });
      bar.appendChild(button);
    };
    AI_ACTIONS.forEach(function(action) {
      addItem({
        act: action.act,
        label: action.label + (dialogs[action.act] ? "\u2026" : ""),
        icon: action.icon,
        ai: true,
        hint: action.hint,
        off: busy,
        offHint: BUSY_HINT,
        run: function() {
          runAI(action.act, node);
        }
      });
    });
    addItem({
      act: "draw",
      label: "Draw",
      icon: "diagram",
      ai: true,
      more: true,
      hint: "The AI draws a diagram of this node as a child node: sequence, flowchart, data flow and more",
      off: busy,
      offHint: BUSY_HINT,
      run: null
    });
    bar.appendChild(h("div", { class: "rm-sep", role: "separator" }));
    addItem({ act: "add", label: "Add child node\u2026", icon: "plus", run: function() {
      addChildDialog(node);
    } });
    addItem({ act: "link", label: "Add logical connection\u2026", icon: "link", off: snap.nodes.length < 2, run: function() {
      linkDialog(node);
    } });
    addItem({ act: "edit", label: "Edit title\u2026", icon: "edit", run: function() {
      editDialog(node);
    } });
    addItem({ act: "icon", label: "Icon\u2026", icon: "tag", hint: "Choose an icon or an emoji for this node", run: function() {
      select(id);
      iconDialog(node);
    } });
    addItem({ act: "image", label: "Image\u2026", icon: "photo", hint: "Add a picture to this node, shown beside its icon", run: function() {
      select(id);
      pictureDialog(node);
    } });
    const kids = snap.nodes.filter(function(n) {
      return n.parent === id;
    });
    const numbered = kids.length > 0 && kids.every(function(n, i) {
      return n.number === i + 1;
    });
    addItem({
      act: "number-children",
      label: numbered ? "Remove numbers from children" : "Number children 1, 2, 3\u2026",
      icon: "text",
      hint: numbered ? "Take the number badges off the child nodes" : "Give the child nodes the number badges 1, 2, 3 in map order",
      off: kids.length === 0,
      offHint: "This node has no children",
      run: function() {
        send("numberChildren", { id, clear: numbered });
      }
    });
    addItem({
      act: "focus",
      label: "Focus on this node",
      icon: "centre",
      hint: "Fold everything except the path from the root to this node and its children",
      run: function() {
        focusNode(id);
      }
    });
    addItem({ act: "arrange", label: "Arrange branch", icon: "grid", more: true, hint: "Choose how this branch lays out its nodes", run: null });
    bar.appendChild(h("div", { class: "rm-sep", role: "separator" }));
    addItem({ act: "delete", label: "Delete node\u2026", icon: "trash", danger: true, off: isRoot, offHint: "The root node cannot be deleted", run: function() {
      deleteDialog(node);
    } });
    el.left.appendChild(bar);
    placeMenu(bar, entry);
    entry.wrap.classList.add("menu-open");
    entry.tri.setAttribute("aria-expanded", "true");
    rm.menu = id;
    rm.menuEl = bar;
  }
  function toggleLayouts(bar, node, anchorButton, entry) {
    const existing = bar.querySelector(".rm-layouts");
    if (existing) {
      existing.remove();
      placeMenu(bar, entry);
      return;
    }
    const layouts = rm.snap.layouts.length ? rm.snap.layouts : Layout.PRESETS.map(function(id) {
      return { id, name: id.charAt(0).toUpperCase() + id.slice(1) };
    });
    const current = Layout.effectiveLayout(rm.snap.nodes, node.id, rm.snap.layouts);
    const list = h("div", { class: "rm-layouts", role: "menu", "aria-label": "Arrange branch" });
    layouts.forEach(function(layout) {
      const on = layout.id === current;
      const button = h("button", { type: "button", role: "menuitemradio", "aria-checked": on ? "true" : "false", "data-layout": layout.id }, h("span", { class: "rm-check" }, on ? "\u2713" : ""), layout.name);
      button.addEventListener("click", function(event) {
        event.stopPropagation();
        closeMenu();
        send("layout", { id: node.id, layout: layout.id });
      });
      list.appendChild(button);
    });
    anchorButton.insertAdjacentElement("afterend", list);
    placeMenu(bar, entry);
  }
  function drawKinds() {
    return rm.snap && rm.snap.drawKinds || [];
  }
  function drawButtons(node, after) {
    return drawKinds().map(function(kind) {
      const button = h("button", { type: "button", role: "menuitem", "data-kind": kind.id, title: kind.hint || kind.name }, kind.name + (kind.id === "custom" ? "\u2026" : ""));
      button.addEventListener("click", function(event) {
        event.stopPropagation();
        after();
        runDraw(node, kind);
      });
      return button;
    });
  }
  function toggleDrawMenu(bar, node, anchorButton, entry) {
    const existing = bar.querySelector(".rm-draw-menu");
    if (existing) {
      existing.remove();
      placeMenu(bar, entry);
      return;
    }
    const list = h("div", { class: "rm-layouts rm-draw-menu", role: "menu", "aria-label": "Diagram types" }, drawButtons(node, closeMenu));
    anchorButton.insertAdjacentElement("afterend", list);
    placeMenu(bar, entry);
  }
  function toggleDrawList() {
    const node = nodeById(rm.selected);
    if (!node) return;
    const open = el.drawList.hidden;
    el.drawList.textContent = "";
    if (open) drawButtons(node, function() {
      toggleDrawList();
    }).forEach(function(b) {
      el.drawList.appendChild(b);
    });
    el.drawList.hidden = !open;
    el.drawBtn.setAttribute("aria-expanded", open ? "true" : "false");
  }
  function runDraw(node, kind) {
    if (aiBusy()) {
      toast(BUSY_HINT);
      return;
    }
    if (kind.id === "custom") {
      textDialog(
        "Draw a diagram",
        "The AI draws a diagram of \u201C" + node.title + "\u201D as a child node.",
        "What should it show?",
        "",
        500,
        "Draw",
        function(text) {
          send("draw", { id: node.id, kind: "custom", instruction: text });
        },
        "Say what the diagram should show.",
        { multiline: true, placeholder: "e.g. the retry rules as a decision flow" }
      );
      return;
    }
    send("draw", { id: node.id, kind: kind.id });
  }
  function runAI(act, node) {
    if (!node) return;
    if (aiBusy()) {
      toast(BUSY_HINT);
      return;
    }
    if (act === "describe") send("describe", { id: node.id });
    else if (act === "investigate") send("investigate", { id: node.id });
    else if (act === "develop") developDialog(node);
    else if (act === "correct") correctDialog(node);
  }
  function renderAI() {
    const busy = aiBusy();
    el.aiButtons.forEach(function(button) {
      button.disabled = busy;
    });
    if (busy && !el.drawList.hidden) toggleDrawList();
    el.aiNote.textContent = busy ? BUSY_HINT : "";
  }
  function toggleExport() {
    if (rm.exportOpen) {
      closeExport();
      return;
    }
    closeMenu();
    closeQueries();
    rm.exportOpen = true;
    el.exportMenu.hidden = false;
    el.exportBtn.setAttribute("aria-expanded", "true");
  }
  function closeExport() {
    rm.exportOpen = false;
    el.exportMenu.hidden = true;
    el.exportBtn.setAttribute("aria-expanded", "false");
  }
  function closeDialog() {
    if (!rm.dialog) return;
    rm.dialog.remove();
    rm.dialog = null;
  }
  function dialog(title, body, actions, label) {
    closeDialog();
    closeMenu();
    const buttons = actions.map(function(action) {
      return h("button", { class: "rm-btn" + (action.kind ? " " + action.kind : ""), type: "button", "data-kind": action.kind || "ghost", onClick: function() {
        if (action.run && action.run() === false) return;
        closeDialog();
      } }, action.label);
    });
    const card = h("div", { class: "rm-dialog", role: "dialog", "aria-modal": "true", "aria-label": label || title }, h("h2", null, title), h("div", { class: "rm-dialog-body" }, body), h("div", { class: "rm-dialog-actions" }, buttons));
    const overlay = h("div", { class: "rm-modal", onPointerdown: function(event) {
      if (event.target === overlay) closeDialog();
    } }, card);
    el.root.appendChild(overlay);
    rm.dialog = overlay;
    const primary = buttons.filter(function(b) {
      return b.classList.contains("primary") || b.classList.contains("danger");
    })[0];
    card.addEventListener("keydown", function(event) {
      if (event.key === "Enter" && primary && (event.target.tagName === "INPUT" || (event.metaKey || event.ctrlKey) && event.target.tagName === "TEXTAREA")) {
        event.preventDefault();
        primary.click();
      }
    });
    const first = card.querySelector("input, textarea, select") || primary || buttons[0];
    if (first) first.focus();
    return overlay;
  }
  function textDialog(title, intro, labelText, initial, maxLength, okLabel, onOk, emptyMessage, options) {
    options = options || {};
    const input = options.multiline ? h("textarea", { maxlength: String(maxLength), "aria-label": labelText, spellcheck: "false", placeholder: options.placeholder || "" }) : h("input", { type: "text", maxlength: String(maxLength), "aria-label": labelText, value: initial || "", spellcheck: "false", placeholder: options.placeholder || "" });
    if (options.multiline) input.value = initial || "";
    const error = h("p", { class: "rm-error", role: "alert" });
    dialog(title, [intro ? h("p", null, intro) : null, h("label", null, labelText, input), error], [
      { label: "Cancel", kind: "ghost" },
      { label: okLabel, kind: "primary", run: function() {
        const value = input.value.trim();
        if (!value && emptyMessage) {
          error.textContent = emptyMessage;
          input.focus();
          return false;
        }
        onOk(value);
      } }
    ]);
    input.select();
  }
  function isEmojiText(value) {
    if (!value) return false;
    const parts = typeof Intl !== "undefined" && Intl.Segmenter ? Array.from(new Intl.Segmenter(void 0, { granularity: "grapheme" }).segment(value)) : [value];
    return parts.length === 1 && new RegExp("\\p{Extended_Pictographic}|\\p{Regional_Indicator}|\\uFE0F", "u").test(value);
  }
  function iconDialog(node) {
    if (!node) return;
    const grid = h("div", { class: "rm-icongrid", role: "group", "aria-label": "Built-in icons" });
    NODE_ICON_IDS.forEach(function(id) {
      const name = id.charAt(0).toUpperCase() + id.slice(1);
      grid.appendChild(h("button", { type: "button", "data-icon": id, title: name, "aria-label": name, "aria-pressed": node.icon === id ? "true" : "false", onClick: function() {
        queueUpdate(node.id, { icon: id }, true);
        closeDialog();
      } }, icon(id, NODE_ICONS)));
    });
    const input = h("input", { type: "text", "aria-label": "Emoji", maxlength: "16", spellcheck: "false", placeholder: "Paste or type one emoji", value: node.icon && !NODE_ICONS[node.icon] ? node.icon : "" });
    const error = h("p", { class: "rm-error", role: "alert" });
    const actions = [{ label: "Cancel", kind: "ghost" }];
    if (node.icon) actions.push({ label: "Remove icon", kind: "ghost", run: function() {
      queueUpdate(node.id, { icon: "" }, true);
    } });
    actions.push({ label: "Use emoji", kind: "primary", run: function() {
      const value = input.value.trim();
      if (!isEmojiText(value)) {
        error.textContent = "Paste one emoji (macOS: Control-Command-Space).";
        input.focus();
        return false;
      }
      queueUpdate(node.id, { icon: value }, true);
    } });
    dialog("Icon for \u201C" + node.title + "\u201D", [grid, h("label", null, "Or any emoji", input), error], actions, "Choose an icon");
  }
  const PICTURE_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"];
  const PICTURE_LIMIT = 6e6;
  function hasFiles(event) {
    return !!(event.dataTransfer && Array.prototype.indexOf.call(event.dataTransfer.types || [], "Files") >= 0);
  }
  function firstFile(transfer) {
    return transfer && transfer.files && transfer.files.length ? transfer.files[0] : null;
  }
  function attachPicture(id, file) {
    if (!file || !nodeById(id)) return "That node no longer exists.";
    if (PICTURE_TYPES.indexOf(file.type) < 0) return "Use a PNG, JPEG, GIF or WebP picture.";
    if (file.size > PICTURE_LIMIT) return "The picture is larger than 6 MB.";
    const reader = new FileReader();
    reader.onload = function() {
      const result = String(reader.result || ""), comma = result.indexOf(",");
      if (comma < 0) {
        toast("The picture could not be read.");
        return;
      }
      send("attachImage", { id, name: file.name || "image", data: result.slice(comma + 1) });
    };
    reader.onerror = function() {
      toast("The picture could not be read.");
    };
    reader.readAsDataURL(file);
    return "";
  }
  function pictureDialog(node) {
    if (!node) return;
    const id = node.id;
    const input = h("input", { type: "file", accept: PICTURE_TYPES.join(","), hidden: true, "aria-label": "Choose a picture file" });
    const preview = h("img", { class: "rm-picture-preview", alt: "", hidden: true });
    const current = node.image ? imageURL(node.image) : null;
    if (current) {
      preview.src = current;
      preview.hidden = false;
    }
    const choose = h("button", { class: "rm-btn", type: "button", "data-act": "choose-picture", onClick: function() {
      input.click();
    } }, "Choose file\u2026");
    const zone = h(
      "div",
      { class: "rm-dropzone", role: "group", "aria-label": "Picture for this node" },
      preview,
      h("span", null, "Drop a picture here, paste it (\u2318V), or choose a file. PNG, JPEG, GIF or WebP, up to 6 MB."),
      choose,
      input
    );
    const error = h("p", { class: "rm-error", role: "alert" });
    const take = function(file) {
      const problem = attachPicture(id, file);
      if (problem) {
        error.textContent = problem;
        return;
      }
      closeDialog();
    };
    input.addEventListener("change", function() {
      take(firstFile(input));
    });
    zone.addEventListener("dragover", function(event) {
      if (hasFiles(event)) {
        event.preventDefault();
        zone.classList.add("over");
      }
    });
    zone.addEventListener("dragleave", function() {
      zone.classList.remove("over");
    });
    zone.addEventListener("drop", function(event) {
      zone.classList.remove("over");
      if (!hasFiles(event)) return;
      event.preventDefault();
      take(firstFile(event.dataTransfer));
    });
    const actions = [{ label: "Cancel", kind: "ghost" }];
    if (node.image) actions.push({ label: "Remove picture", kind: "ghost", run: function() {
      queueUpdate(id, { image: "" }, true);
    } });
    const overlay = dialog("Picture for \u201C" + node.title + "\u201D", [zone, error], actions, "Choose a picture");
    overlay.addEventListener("paste", function(event) {
      const file = firstFile(event.clipboardData);
      if (!file) return;
      event.preventDefault();
      take(file);
    });
  }
  (function() {
    let over = "";
    const mark = function(id) {
      if (id === over) return;
      const old = over && rm.els.get(over);
      if (old) old.wrap.classList.remove("picture-drop");
      over = id;
      const entry = id && rm.els.get(id);
      if (entry) entry.wrap.classList.add("picture-drop");
    };
    const nodeAt = function(event) {
      const wrap = event.target && event.target.closest ? event.target.closest(".rm-node-wrap") : null;
      return wrap ? wrap.getAttribute("data-id") : "";
    };
    el.viewport.addEventListener("dragover", function(event) {
      const id = hasFiles(event) ? nodeAt(event) : "";
      mark(id);
      if (!id) return;
      event.preventDefault();
      event.dataTransfer.dropEffect = "copy";
    });
    el.viewport.addEventListener("dragleave", function(event) {
      if (!event.relatedTarget || !el.viewport.contains(event.relatedTarget)) mark("");
    });
    el.viewport.addEventListener("drop", function(event) {
      mark("");
      const id = hasFiles(event) ? nodeAt(event) : "";
      if (!id) return;
      event.preventDefault();
      event.stopPropagation();
      const problem = attachPicture(id, firstFile(event.dataTransfer));
      if (problem) toast(problem);
      else select(id);
    });
  })();
  function addChildDialog(parent) {
    textDialog("Add child node", "Parent node: " + parent.title, "Child node name", "", MAX_TITLE, "Add", function(title) {
      send("addChild", { parent: parent.id, title });
    }, "Enter a node name.");
  }
  function editDialog(node) {
    textDialog("Edit node", "", "Node name", node.title, MAX_TITLE, "Save", function(title) {
      send("update", { id: node.id, title });
    }, "Enter a node name.");
  }
  function developDialog(node) {
    textDialog(
      "Expand topic",
      "The AI adds child nodes under \u201C" + node.title + "\u201D.",
      "Direction (optional)",
      "",
      500,
      "Expand",
      function(direction) {
        send("develop", { id: node.id, direction });
      },
      "",
      { placeholder: "e.g. compare the options, or focus on the costs" }
    );
  }
  function correctDialog(node) {
    textDialog(
      "Correct node",
      "The AI checks \u201C" + node.title + "\u201D against the project and the web and fixes only this node.",
      "What is wrong with it?",
      "",
      2e3,
      "Correct",
      function(note) {
        send("correct", { id: node.id, note });
      },
      "Say what is wrong with this node.",
      { multiline: true, placeholder: "e.g. the cache is not LRU, it evicts by size" }
    );
  }
  function savedLanguage(key) {
    try {
      return localStorage.getItem(key) || "";
    } catch (e) {
      return "";
    }
  }
  function saveLanguage(key, value) {
    try {
      localStorage.setItem(key, value);
    } catch (e) {
    }
  }
  function languagePicker(storageKey, withOwn) {
    const languages = rm.snap && rm.snap.languages && rm.snap.languages.length ? rm.snap.languages : [{ code: "en", name: "English" }];
    const select2 = h("select", { "aria-label": "Language" });
    if (withOwn) select2.appendChild(h("option", { value: "" }, "The language of the map"));
    languages.forEach(function(l) {
      select2.appendChild(h("option", { value: l.name }, l.name));
    });
    select2.appendChild(h("option", { value: "__other" }, "Other\u2026"));
    const other = h("input", { type: "text", maxlength: "40", "aria-label": "Language name", placeholder: "e.g. Japanese", spellcheck: "false", hidden: true });
    const saved = savedLanguage(storageKey);
    const known = Array.prototype.some.call(select2.options, function(o) {
      return o.value === saved;
    });
    if (saved && known) select2.value = saved;
    else if (saved) {
      select2.value = "__other";
      other.value = saved;
      other.hidden = false;
    } else select2.value = withOwn ? "" : languages[0].name;
    select2.addEventListener("change", function() {
      other.hidden = select2.value !== "__other";
      if (!other.hidden) other.focus();
    });
    return {
      nodes: [h("label", null, "Language", select2), other],
      /** The chosen language name, '' for the map's own, or null with a message when Other… is empty. */
      value: function() {
        return select2.value === "__other" ? other.value.trim().replace(/\s+/g, " ") : select2.value;
      },
      needsName: function() {
        return select2.value === "__other" && !other.value.trim();
      },
      remember: function() {
        saveLanguage(storageKey, select2.value === "__other" ? other.value.trim() : select2.value);
      },
      focusOther: function() {
        other.focus();
      }
    };
  }
  function exportDialog(kind) {
    if (aiBusy()) {
      toast(BUSY_HINT);
      return;
    }
    const picker = languagePicker("mvMapLang:export", true);
    const error = h("p", { class: "rm-error", role: "alert" });
    const pdf = kind === "pdf";
    dialog(
      pdf ? "Export as PDF" : "Export as Markdown report",
      [h("p", null, "The AI writes a report of the whole map as a document to share: an introduction, the story of each branch, conclusions and open questions, with the map\u2019s diagrams and pictures where they belong. It takes a few minutes."), picker.nodes, error],
      [
        { label: "Cancel", kind: "ghost" },
        { label: pdf ? "Export\u2026" : "Export", kind: "primary", run: function() {
          if (picker.needsName()) {
            error.textContent = "Type the name of the language.";
            picker.focusOther();
            return false;
          }
          picker.remember();
          send("export", { kind, language: picker.value() });
        } }
      ],
      pdf ? "Export as PDF" : "Export as Markdown report"
    );
  }
  function translateDialog() {
    if (aiBusy()) {
      toast(BUSY_HINT);
      return;
    }
    const picker = languagePicker("mvMapLang:translate", false);
    const mode = h(
      "select",
      { "aria-label": "Result" },
      h("option", { value: "copy" }, "A new map next to this one"),
      h("option", { value: "replace" }, "Replace this map (a copy is saved first)")
    );
    const error = h("p", { class: "rm-error", role: "alert" });
    dialog(
      "Translate map",
      [h("p", null, "The AI translates the question and the text of every node. The structure, the sources and the links stay exactly as they are."), picker.nodes, h("label", null, "Result", mode), error],
      [
        { label: "Cancel", kind: "ghost" },
        { label: "Translate", kind: "primary", run: function() {
          if (picker.needsName() || !picker.value()) {
            error.textContent = "Choose or type a language.";
            picker.focusOther();
            return false;
          }
          picker.remember();
          send("translate", { language: picker.value(), mode: mode.value });
        } }
      ],
      "Translate map"
    );
  }
  function nodeOptions(nodes) {
    const depth = function(n) {
      let d = 0, cur = n, guard = 0;
      while (cur && cur.parent && guard++ < 100) {
        d++;
        cur = rm.snap.byId.get(cur.parent);
      }
      return d;
    };
    return nodes.map(function(n) {
      return h("option", { value: n.id }, "\u2007".repeat(Math.min(depth(n), 6)) + n.title);
    });
  }
  function linkDialog(node) {
    const nodes = rm.snap.nodes;
    const from = h("select", { "aria-label": "First node" }, nodeOptions(nodes));
    const to = h("select", { "aria-label": "Second node" }, nodeOptions(nodes));
    from.value = node.id;
    const other = nodes.filter(function(n) {
      return n.id !== node.id;
    })[0];
    if (other) to.value = other.id;
    const error = h("p", { class: "rm-error", role: "alert" });
    dialog("Add logical connection", [h("label", null, "First node", from), h("label", null, "Second node", to), error], [
      { label: "Cancel", kind: "ghost" },
      { label: "Add", kind: "primary", run: function() {
        if (from.value === to.value) {
          error.textContent = "Select two different nodes.";
          return false;
        }
        if (rm.snap.links.some(function(l) {
          return l.from === from.value && l.to === to.value || l.from === to.value && l.to === from.value;
        })) {
          error.textContent = "This connection already exists.";
          return false;
        }
        send("link", { from: from.value, to: to.value });
      } }
    ]);
  }
  function deleteDialog(node) {
    const below = descendantIds(node.id).length - 1;
    const message = "Delete node \u201C" + node.title + "\u201D" + (below > 0 ? " and its child nodes (" + below + ")" : "") + "? Its logical connections will also be deleted.";
    dialog("Delete node", h("p", null, message), [
      { label: "Cancel", kind: "ghost" },
      { label: "Delete", kind: "danger", run: function() {
        rm.fallbackSelect = node.parent;
        send("delete", { id: node.id });
      } }
    ]);
  }
})(window.MVResearchMapView);
;
(function(A) {
  "use strict";
  if (!A.ready) return;
  const {
    LIMITS,
    NODE_ICON_IDS,
    SHAPE_IDS,
    closeDialog,
    closeExport,
    closeMenu,
    closeQueries,
    diagramSourceOf,
    el,
    fillPanel,
    flushAll,
    hideProblem,
    imageOf,
    isResearchMapText,
    modeSwitch,
    render,
    reportError,
    rm,
    saveNow,
    send,
    stopTicker,
    syncVisual,
    toast,
    withDiagram,
    withImage
  } = A;
  Object.assign(A, { showView });
  document.addEventListener("pointerdown", function(event) {
    if (!rm.active) return;
    if (rm.menu != null && !event.target.closest(".rm-node-wrap.menu-open, .rm-actions")) closeMenu();
    if (rm.queriesOpen && !event.target.closest('.rm-popover, [data-act="queries"]')) closeQueries();
    if (rm.exportOpen && !event.target.closest('.rm-exportmenu, [data-act="export"]')) closeExport();
  }, true);
  el.root.addEventListener("keydown", function(event) {
    if (event.key !== "Escape") return;
    if (rm.dialog) {
      closeDialog();
      event.stopPropagation();
    } else if (rm.menu != null) {
      closeMenu();
      event.stopPropagation();
    } else if (rm.queriesOpen) {
      closeQueries();
      event.stopPropagation();
    } else if (rm.exportOpen) {
      closeExport();
      event.stopPropagation();
    }
  });
  function resetForDocument(docId) {
    flushAll();
    clearTimeout(rm.saveTimer);
    saveNow();
    closeMenu();
    closeDialog();
    closeQueries();
    closeExport();
    rm.els.forEach(function(entry) {
      entry.wrap.remove();
    });
    rm.els.clear();
    while (el.svg.firstChild) el.svg.removeChild(el.svg.firstChild);
    rm.docId = docId;
    rm.snap = null;
    rm.mapKey = "";
    rm.selected = null;
    rm.panelFor = null;
    rm.positions = {};
    rm.moves = {};
    rm.drag = null;
    rm.resize = null;
    rm.boxes = {};
    rm.collapsed = /* @__PURE__ */ new Set();
    rm.viewReady = false;
    el.status.hidden = true;
    el.queriesBtn.hidden = true;
    el.title.textContent = "";
    el.question.textContent = "";
    el.loading.textContent = "Loading the research map\u2026";
    el.empty.hidden = false;
    el.body.hidden = true;
  }
  function enterMap() {
    const docId = window.mvDocumentId || "";
    if (rm.docId !== docId) resetForDocument(docId);
    if (typeof window.leaveCodeView === "function") window.leaveCodeView();
    if (typeof window.leaveArchitectureView === "function") window.leaveArchitectureView();
    if (typeof window.leaveCanvasView === "function") window.leaveCanvasView();
    if (typeof window.leaveDataView === "function") window.leaveDataView();
    if (typeof leaveInsightView === "function") leaveInsightView();
    state.mode = "research-map";
    DOM.editorPane.style.display = "none";
    DOM.previewPane.style.display = "none";
    const bar = document.getElementById("wysiwyg-toolbar");
    if (bar) bar.style.display = "none";
    if (DOM.statusMode) DOM.statusMode.textContent = "MAP";
    document.body.classList.add("research-map-mode");
    el.root.classList.add("visible");
    rm.active = true;
    hideProblem();
    syncModes();
    watchTheme();
    if (rm.snap) render();
    send("snapshot");
  }
  function watchTheme() {
    if (rm.themeWatch || typeof MutationObserver === "undefined") return;
    rm.themeWatch = new MutationObserver(function() {
      if (!rm.active || !rm.snap) return;
      rm.snap.nodes.forEach(function(n) {
        const entry = rm.els.get(n.id);
        if (entry) syncVisual(entry, n, n.title);
      });
      fillPanel();
    });
    rm.themeWatch.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme", "data-preset", "data-accent"] });
  }
  window.leaveResearchMap = function() {
    flushAll();
    closeMenu();
    closeDialog();
    closeQueries();
    closeExport();
    stopTicker();
    saveNow();
    rm.active = false;
    if (!el.root.classList.contains("visible")) return;
    el.root.classList.remove("visible");
    document.body.classList.remove("research-map-mode");
    const bar = document.getElementById("wysiwyg-toolbar");
    if (bar) bar.style.display = "";
    syncModes();
  };
  function goSource() {
    window.leaveResearchMap();
    window.switchToSource();
  }
  function currentView() {
    if (rm.active) return "map";
    if (!isResearchMapText(DOM.editor.value)) return null;
    if (state.mode === "preview") return "view";
    if (state.mode === "source") return "source";
    return null;
  }
  const topBar = document.getElementById("wysiwyg-toolbar"), topLabel = document.getElementById("mode-toggle");
  el.topModes = modeSwitch();
  el.topModes.hidden = true;
  if (topBar && topLabel && topLabel.parentNode === topBar) topBar.insertBefore(el.topModes, topLabel);
  let viewLocked = false;
  function syncModes() {
    const view = currentView();
    [el.modes, el.topModes].forEach(function(group) {
      Array.prototype.forEach.call(group.querySelectorAll("button"), function(b) {
        b.setAttribute("aria-pressed", b.getAttribute("data-view") === view ? "true" : "false");
      });
    });
    el.topModes.hidden = view === null;
    if (topLabel) topLabel.style.display = view === null ? "" : "none";
    const lock = view === "view";
    document.body.classList.toggle("rm-view-readonly", lock);
    if (lock && DOM.rendered) {
      DOM.rendered.contentEditable = "false";
      viewLocked = true;
    } else if (viewLocked && DOM.rendered) {
      DOM.rendered.contentEditable = "true";
      viewLocked = false;
    }
  }
  function showView(view) {
    const now = currentView();
    if (now === null || view === now) return;
    if (view === "map") enterMap();
    else if (view === "view") {
      window.leaveResearchMap();
      window.switchToPreview();
    } else goSource();
    syncModes();
  }
  function cycleView() {
    const view = currentView();
    if (view === null) return false;
    showView(view === "map" ? "view" : view === "view" ? "source" : "map");
    return true;
  }
  const originalSetContent = window.setContent;
  window.setContent = function(markdown) {
    const result = typeof originalSetContent === "function" ? originalSetContent.apply(this, arguments) : void 0;
    try {
      if (isResearchMapText(markdown)) {
        rm.sourceBase = markdown;
        enterMap();
      } else {
        hideProblem();
        window.leaveResearchMap();
      }
      syncModes();
    } catch (e) {
      reportError("setContent", e);
    }
    return result;
  };
  ["setStructuredContent", "setCodeContent", "setDataContent", "showArchitecture", "loadInsightSkeleton"].forEach(function(name) {
    const original = window[name];
    if (typeof original !== "function") return;
    window[name] = function() {
      hideProblem();
      window.leaveResearchMap();
      const result = original.apply(this, arguments);
      syncModes();
      return result;
    };
  });
  ["switchToSource", "switchToPreview"].forEach(function(name) {
    const original = window[name];
    if (typeof original !== "function") return;
    window[name] = function() {
      window.leaveResearchMap();
      const result = original.apply(this, arguments);
      syncModes();
      return result;
    };
  });
  ["toggleModeWrapper", "toggleMode", "toggleSourceMode"].forEach(function(name) {
    const original = window[name];
    if (typeof original !== "function") return;
    window[name] = function() {
      if (cycleView()) return void 0;
      return original.apply(this, arguments);
    };
  });
  const originalSetDocument = window.mvSetDocument;
  if (typeof originalSetDocument === "function") {
    window.mvSetDocument = function(id) {
      if (String(id || "") !== String(window.mvDocumentId || "")) {
        try {
          flushAll();
        } catch (e) {
          reportError("mvSetDocument", e);
        }
      }
      return originalSetDocument.apply(this, arguments);
    };
  }
  window.MVResearchMap = {
    iconIDs: function() {
      return NODE_ICON_IDS.slice();
    },
    shapeIDs: function() {
      return SHAPE_IDS.slice();
    },
    sizeLimits: function() {
      return { width: LIMITS.width.slice(), height: LIMITS.height.slice() };
    },
    notice: function(message) {
      toast(String(message));
    },
    collapsed: function() {
      return Array.from(rm.collapsed);
    },
    isResearchMapText,
    visual: { diagramSourceOf, imageOf, withDiagram, withImage },
    viewState: function() {
      return { active: rm.active, x: rm.view.x, y: rm.view.y, scale: rm.view.scale, panel: rm.panelWidth, selected: rm.selected, key: rm.mapKey };
    }
  };
})(window.MVResearchMapView);
;
DOM.editor.addEventListener("input", () => {
  state.markdown = DOM.editor.value;
  if (state.fileType === "markdown") {
    renderMarkdown();
    updateStats();
  } else {
    sendToSwift("contentChanged", { markdown: state.markdown, html: "" });
  }
});
DOM.btnToggleMode.addEventListener("click", function() {
  if (state.fileType !== "markdown") {
    toggleStructMode();
  } else {
    toggleMode();
  }
});
DOM.rendered.addEventListener("click", function(e) {
  const link = e.target.closest("a");
  if (!link) return;
  const rawHref = link.getAttribute("href");
  if (!rawHref) return;
  e.preventDefault();
  e.stopPropagation();
  if (rawHref.startsWith("#")) {
    const targetId = decodeURIComponent(rawHref.substring(1));
    const target = document.getElementById(targetId);
    if (target) {
      target.scrollIntoView({ behavior: "smooth" });
      sendToSwift("scrollPosition", { activeHeadingId: targetId });
    }
    return;
  }
  sendToSwift("linkClicked", { href: link.href });
});
document.addEventListener("keydown", (e) => {
  if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.code === "KeyP") {
    e.preventDefault();
    toggleMode();
  }
});
function init() {
  if (!state.documentBaseURL && document.baseURI && document.baseURI.startsWith("file://")) {
    state.documentBaseURL = document.baseURI;
  }
  DOM.editor.focus();
  sendToSwift("ready", {});
}
(function bindDeclarativeActions() {
  document.querySelectorAll("[data-mv-prevent-mousedown]").forEach(function(el) {
    el.addEventListener("mousedown", function(e) {
      e.preventDefault();
    });
  });
  document.querySelectorAll("[data-mv-action]").forEach(function(el) {
    el.addEventListener("click", function() {
      const spec = el.getAttribute("data-mv-action") || "";
      const parts = spec.split(":");
      const fn = parts[0];
      const arg1 = parts[1];
      const arg2 = parts[2];
      switch (fn) {
        case "findPrev":
          if (typeof findPrev === "function") findPrev();
          break;
        case "findNext":
          if (typeof findNext === "function") findNext();
          break;
        case "toggleFindCase":
          if (typeof toggleFindCase === "function") toggleFindCase();
          break;
        case "toggleFindRegex":
          if (typeof toggleFindRegex === "function") toggleFindRegex();
          break;
        case "closeFind":
          if (typeof closeFind === "function") closeFind();
          break;
        case "fmtCmd":
          if (typeof fmtCmd === "function") fmtCmd(arg1, arg2);
          break;
        case "fmtBlock":
          if (typeof fmtBlock === "function") fmtBlock(arg1);
          break;
        case "fmtHeading":
          if (typeof fmtHeading === "function") fmtHeading();
          break;
        case "fmtLink":
          if (typeof fmtLink === "function") fmtLink();
          break;
        case "fmtCodeBlock":
          if (typeof fmtCodeBlock === "function") fmtCodeBlock();
          break;
        case "fmtImage":
          if (typeof fmtImage === "function") fmtImage();
          break;
        case "fmtHR":
          if (typeof fmtHR === "function") fmtHR();
          break;
        case "fmtTable":
          if (typeof fmtTable === "function") fmtTable();
          break;
        case "fmtMermaid":
          if (typeof fmtMermaid === "function") fmtMermaid();
          break;
        case "saveFile":
          if (typeof saveFile === "function") saveFile();
          break;
        case "refreshFile":
          if (typeof refreshFile === "function") refreshFile();
          break;
        case "selectionAction":
          if (typeof selectionAction === "function") selectionAction(arg1);
          break;
        case "showFeatureMenu":
          if (typeof showFeatureMenu === "function") showFeatureMenu();
          break;
        case "featureAction":
          if (typeof featureAction === "function") featureAction(arg1);
          break;
        case "closeActionPopup":
          if (typeof closeActionPopup === "function") closeActionPopup();
          break;
        case "toggleMode":
          if (typeof toggleModeWrapper === "function") toggleModeWrapper();
          else if (typeof toggleMode === "function") toggleMode();
          break;
      }
    });
  });
  const featureAsk = document.getElementById("feature-ask");
  if (featureAsk) {
    featureAsk.addEventListener("keydown", function(event) {
      if (event.key === "Enter" && typeof featureAction === "function") featureAction("ask");
      if (event.key === "Escape" && typeof hideFeatureMenu === "function") hideFeatureMenu();
    });
  }
  const more = document.querySelector(".editor-more");
  if (more) {
    const menu = more.querySelector(".editor-more-menu");
    if (menu) {
      menu.addEventListener("click", function(event) {
        if (event.target.closest("button")) more.open = false;
      });
    }
    document.addEventListener("click", function(event) {
      if (!more.contains(event.target)) more.open = false;
    });
  }
})();
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", init);
} else {
  init();
}
