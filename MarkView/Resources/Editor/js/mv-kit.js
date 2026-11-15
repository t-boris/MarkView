// ============================================================================
// MV-KIT & MV-BRIDGE — Shared Web Primitives & Typed Bridge Registry (AR-28, AR-29)
// ============================================================================
(function(global) {
    'use strict';

    var HTML_ESCAPES = {
        '&': '&amp;',
        '<': '&lt;',
        '>': '&gt;',
        '"': '&quot;',
        "'": '&#39;'
    };

    function escapeHtml(value) {
        if (value === null || value === undefined) return '';
        return String(value).replace(/[&<>"']/g, function(ch) {
            return HTML_ESCAPES[ch] || ch;
        });
    }

    function escapeAttr(value) {
        return escapeHtml(value).replace(/`/g, '&#96;');
    }

    function debounce(fn, waitMs) {
        var timer = null;
        var delay = typeof waitMs === 'number' && waitMs >= 0 ? waitMs : 150;
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
        if (attrs && typeof attrs === 'object') {
            Object.keys(attrs).forEach(function(key) {
                var val = attrs[key];
                if (val === null || val === undefined || val === false) return;
                if (key === 'className') {
                    el.className = String(val);
                } else if (key === 'textContent') {
                    el.textContent = String(val);
                } else if (key === 'style' && typeof val === 'object') {
                    Object.keys(val).forEach(function(prop) {
                        el.style[prop] = val[prop];
                    });
                } else if (key.indexOf('on') === 0 && typeof val === 'function') {
                    el.addEventListener(key.slice(2).toLowerCase(), val);
                } else {
                    el.setAttribute(key, val === true ? '' : String(val));
                }
            });
        }
        if (Array.isArray(children)) {
            children.forEach(function(child) {
                if (child === null || child === undefined) return;
                el.appendChild(typeof child === 'string' ? document.createTextNode(child) : child);
            });
        } else if (typeof children === 'string') {
            el.textContent = children;
        } else if (children && children.nodeType) {
            el.appendChild(children);
        }
        return el;
    }

    function attachPanZoom(container, target, options) {
        if (!container || !target) return { reset: function() {} };
        var opts = options || {};
        var minScale = opts.minScale || 0.2;
        var maxScale = opts.maxScale || 5.0;
        var state = { x: 0, y: 0, scale: 1, dragging: false, startX: 0, startY: 0 };

        function apply() {
            target.style.transform = 'translate(' + state.x + 'px, ' + state.y + 'px) scale(' + state.scale + ')';
        }

        container.addEventListener('wheel', function(e) {
            e.preventDefault();
            var factor = e.deltaY < 0 ? 1.1 : 0.9;
            state.scale = Math.min(maxScale, Math.max(minScale, state.scale * factor));
            apply();
        }, { passive: false });

        container.addEventListener('mousedown', function(e) {
            if (e.button !== 0) return;
            state.dragging = true;
            state.startX = e.clientX - state.x;
            state.startY = e.clientY - state.y;
        });

        global.addEventListener('mousemove', function(e) {
            if (!state.dragging) return;
            state.x = e.clientX - state.startX;
            state.y = e.clientY - state.startY;
            apply();
        });

        global.addEventListener('mouseup', function() {
            state.dragging = false;
        });

        return {
            reset: function() {
                state.x = 0;
                state.y = 0;
                state.scale = 1;
                apply();
            },
            getState: function() {
                return { x: state.x, y: state.y, scale: state.scale };
            }
        };
    }

    // Typed JS -> Swift messages (AR-28). The app gives each page the one contract (Editor/js/bridge-contract.json) as
    // window.mvBridgeContract before any script runs; `send` checks a message against it and refuses what the app would refuse:
    // a channel or type that is not declared, a missing or mistyped field. A refusal is logged to the console with the type and
    // field names (never the values) and nothing is posted. The Swift side (TypedWebBridge) validates the same declaration again.
    var BRIDGE_KINDS = { string: 1, int: 1, number: 1, boolean: 1, object: 1, array: 1, any: 1 };
    var UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    var compiledContract = null;
    var compiledFrom = null;
    var warnedNoContract = false;

    // A spec is a type name (a primitive or a definition), optionally ending in `?`, or an object with `type` and its options.
    function compileSpec(raw, definitions, depth) {
        if (depth > 8) throw new Error('definitions nest too deep');
        var options = {};
        var typeName;
        var optional = false;
        if (typeof raw === 'string') {
            typeName = raw;
        } else if (raw && typeof raw === 'object' && typeof raw.type === 'string') {
            typeName = raw.type;
            options = raw;
            optional = options.optional === true;
        } else {
            throw new Error('not a type');
        }
        if (typeName.charAt(typeName.length - 1) === '?') {
            optional = true;
            typeName = typeName.slice(0, -1);
        }
        if (!BRIDGE_KINDS[typeName]) {
            if (!definitions || !definitions[typeName]) throw new Error('unknown type ' + typeName);
            var resolved = compileSpec(definitions[typeName], definitions, depth + 1);
            resolved.optional = optional || resolved.optional;
            return resolved;
        }
        var spec = {
            kind: typeName,
            optional: optional,
            nonEmpty: options.nonEmpty === true,
            min: typeof options.min === 'number' ? options.min : null,
            max: typeof options.max === 'number' ? options.max : null,
            maxItems: typeof options.maxItems === 'number' ? options.maxItems : null,
            allowed: null,
            isUUID: options.format === 'uuid',
            fields: null,
            items: null
        };
        if (Array.isArray(options.enum)) {
            spec.allowed = Object.create(null);
            options.enum.forEach(function(value) { spec.allowed[value] = true; });
        }
        if (options.fields) spec.fields = compileFields(options.fields, definitions);
        if (options.items !== undefined) spec.items = compileSpec(options.items, definitions, depth + 1);
        return spec;
    }

    function compileFields(fields, definitions) {
        var compiled = {};
        Object.keys(fields).forEach(function(name) { compiled[name] = compileSpec(fields[name], definitions, 0); });
        return compiled;
    }

    function compileContract(contract) {
        var channels = Object.create(null);
        var definitions = contract.definitions || {};
        Object.keys(contract.channels).forEach(function(channelName) {
            var messages = Object.create(null);
            var declared = contract.channels[channelName].messages;
            Object.keys(declared).forEach(function(type) {
                var entry = declared[type];
                var payload = entry.fields
                    ? { kind: 'object', optional: false, fields: compileFields(entry.fields, definitions) }
                    : { kind: 'array', optional: false, items: compileSpec(entry.items, definitions, 0) };
                messages[type] = { payload: payload, mainFrameOnly: entry.mainFrameOnly === true };
            });
            channels[channelName] = messages;
        });
        return channels;
    }

    function contractChannels() {
        var contract = global.mvBridgeContract;
        if (!contract || typeof contract !== 'object' || !contract.channels) return null;
        if (compiledFrom !== contract) {
            compiledContract = compileContract(contract);
            compiledFrom = contract;
        }
        return compiledContract;
    }

    // What is wrong with `value` against `spec`, or ''. Names the field and the rule, never the value.
    function bridgeProblem(spec, value, path) {
        if (value === undefined || value === null) return spec.optional ? '' : path + ' is missing';
        switch (spec.kind) {
            case 'any':
                return '';
            case 'string':
                if (typeof value !== 'string') return path + ' is not a string';
                if (spec.nonEmpty && value.length === 0) return path + ' is empty';
                if (spec.allowed && spec.allowed[value] !== true) return path + ' is not a declared value';
                if (spec.isUUID && !UUID_PATTERN.test(value)) return path + ' is not a UUID';
                return '';
            case 'int':
            case 'number':
                if (typeof value !== 'number') return path + ' is not a ' + (spec.kind === 'int' ? 'whole number' : 'number');
                if (!isFinite(value)) return path + ' is not finite';
                if (spec.kind === 'int' && (Math.floor(value) !== value || Math.abs(value) > 9007199254740992)) return path + ' is not a whole number';
                if (spec.min !== null && value < spec.min) return path + ' is below its minimum';
                if (spec.max !== null && value > spec.max) return path + ' is above its maximum';
                return '';
            case 'boolean':
                return typeof value === 'boolean' ? '' : path + ' is not a boolean';
            case 'object':
                if (typeof value !== 'object' || Array.isArray(value)) return path + ' is not an object';
                if (spec.fields) {
                    var names = Object.keys(spec.fields);
                    for (var i = 0; i < names.length; i++) {
                        var problem = bridgeProblem(spec.fields[names[i]], value[names[i]], path + '.' + names[i]);
                        if (problem) return problem;
                    }
                }
                return '';
            case 'array':
                if (!Array.isArray(value)) return path + ' is not an array';
                if (spec.maxItems !== null && value.length > spec.maxItems) return path + ' has too many items';
                if (spec.items) {
                    for (var j = 0; j < value.length; j++) {
                        var itemProblem = bridgeProblem(spec.items, value[j], path + '[' + j + ']');
                        if (itemProblem) return itemProblem;
                    }
                }
                return '';
        }
        return path + ' has an unknown type';
    }

    // The reason `send` would refuse this message, or ''.
    function outboundProblem(channel, type, payload) {
        var channels = contractChannels();
        if (!channels) return 'no bridge contract on this page';
        var messages = channels[channel];
        if (!messages) return 'channel ' + channel + ' is not in the contract';
        var message = messages[String(type)];
        if (!message) return channel + '/' + String(type) + ' is not in the contract';
        if (payload === undefined && message.payload.kind === 'object') payload = {};
        var problem = bridgeProblem(message.payload, payload, 'payload');
        return problem ? channel + '/' + type + ': ' + problem : '';
    }

    var mvBridge = {
        // Posts one message to the app. Returns false when the message was refused or the page has no app to send it to.
        send: function(type, payload, channel) {
            var name = channel || 'bridge';
            var problem = outboundProblem(name, type, payload);
            if (problem) {
                if (problem === 'no bridge contract on this page') {
                    if (warnedNoContract) return false;
                    warnedNoContract = true;
                }
                if (global.console && global.console.error) global.console.error('[mvBridge] refused: ' + problem);
                return false;
            }
            var handler = global.webkit && global.webkit.messageHandlers && global.webkit.messageHandlers[name];
            if (!handler) return false;
            handler.postMessage({
                type: type,
                payload: payload !== undefined ? payload : {},
                doc: global.mvDocumentId || ''
            });
            return true;
        }
    };

    // What an inline style or an SVG stylesheet may set (FU-24): box, text and SVG paint properties, and custom properties.
    // Everything not listed is dropped, among it z-index, content, behavior, -moz-binding, zoom and appearance. `position` is
    // limited to static and relative: `fixed` covers the whole window (it paints over the editor's toolbar), and `absolute`
    // is only contained where an ancestor is positioned and clips (the editor pane, a book page), not in the discussion
    // thread, so one shared rule has to refuse it too. A vendor-prefixed name is checked without its `-webkit-`.
    var STYLE_PROPERTY_ALLOW = new RegExp('^(?:' + [
        '(?:align|justify|place)-[a-z-]+', 'alignment-baseline', 'animation(?:-[a-z-]+)?', 'aspect-ratio', 'backdrop-filter',
        'backface-visibility', 'background(?:-[a-z-]+)?', 'baseline-shift', 'border(?:-[a-z-]+)?', 'bottom', 'box-[a-z-]+', 'caption-side', 'clear',
        'clip-path', 'clip-rule', 'color', 'color-interpolation(?:-filters)?', 'column-[a-z-]+', 'columns', 'counter-[a-z-]+',
        'cursor', 'cx', 'cy', 'direction', 'display', 'dominant-baseline', 'empty-cells', 'fill(?:-[a-z-]+)?', 'filter', 'flex(?:-[a-z-]+)?',
        'float', 'flood-[a-z-]+', 'font(?:-[a-z-]+)?', 'gap', 'grid(?:-[a-z-]+)?', 'height', 'hyphens', 'image-rendering',
        'inset(?:-[a-z-]+)?', 'left', 'letter-spacing', 'lighting-color', 'line-[a-z-]+', 'list-style(?:-[a-z-]+)?',
        'margin(?:-[a-z-]+)?', 'marker(?:-[a-z-]+)?', 'mask(?:-[a-z-]+)?', 'max-[a-z-]+', 'min-[a-z-]+', 'mix-blend-mode',
        'object-[a-z-]+', 'opacity', 'order', 'orphans', 'outline(?:-[a-z-]+)?', 'overflow(?:-[a-z-]+)?',
        'padding(?:-[a-z-]+)?', 'paint-order', 'perspective(?:-[a-z-]+)?', 'pointer-events', 'position', 'quotes', 'r', 'right',
        'rotate', 'row-gap', 'rx', 'ry', 'scale', 'shape-rendering', 'stop-[a-z-]+', 'stroke(?:-[a-z-]+)?', 'tab-size', 'table-layout',
        'text-[a-z-]+', 'top', 'transform(?:-[a-z-]+)?', 'transition(?:-[a-z-]+)?', 'translate', 'unicode-bidi', 'user-select',
        'vector-effect', 'vertical-align', 'visibility', 'white-space', 'widows', 'width', 'word-[a-z-]+', 'writing-mode'
    ].join('|') + ')$');
    // CSS functions that fetch what a string or an address names, and the legacy script hooks.
    var STYLE_VALUE_UNSAFE = /(?:^|[^\w-])(?:-webkit-)?(?:image|image-set|cross-fade|element|paint|canvas|src)\(|expression\s*\(|javascript:|vbscript:|@import|-moz-binding|behavior\s*:/i;
    var STYLE_URL = /url\(\s*(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|([^)"'\s]*))\s*\)/gi;
    // One style attribute or rule that expands to more longhands than this is not a style a person wrote (`all: unset` expands to ~300).
    var MAX_STYLE_DECLARATIONS = 200;
    var URL_ATTRS = ['src', 'href', 'xlink:href', 'action', 'formaction', 'poster'];
    var COMMON_FORBID_TAGS = ['script', 'iframe', 'object', 'embed', 'form', 'base', 'meta', 'link', 'style'];
    var COMMON_FORBID_ATTR = [
        'onerror', 'onload', 'onclick', 'onmouseover', 'onmouseenter', 'onmouseleave',
        'onfocus', 'onblur', 'onkeydown', 'onkeyup', 'onkeypress', 'onsubmit',
        'onchange', 'oninput', 'onmousedown', 'onmouseup', 'oncontextmenu', 'ondblclick',
        'ondrag', 'ondrop', 'onpaste', 'oncopy', 'oncut', 'onanimationstart',
        'onanimationend', 'ontoggle'
    ];
    var SANITIZE_PROFILES = {
        markdown: {
            ADD_TAGS: ['details', 'summary', 'input', 'annotation', 'semantics'],
            ADD_ATTR: ['target', 'checked', 'disabled', 'type', 'open', 'contenteditable', 'aria-hidden', 'style', 'class', 'id', 'title', 'alt', 'src', 'href', 'width', 'height', 'align', 'colspan', 'rowspan'],
            ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto|tel|markview-doc|markview-wikilink):|data:image\/(?:png|jpe?g|gif|webp|avif)[;,]|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i,
            FORBID_TAGS: COMMON_FORBID_TAGS
        },
        book: {
            ADD_TAGS: ['details', 'summary', 'input', 'annotation', 'semantics', 'book-preserve'],
            ADD_ATTR: ['target', 'checked', 'disabled', 'type', 'open', 'aria-hidden', 'style', 'class', 'id', 'title', 'alt', 'src', 'href', 'width', 'height', 'colspan', 'rowspan', 'start', 'data-wikilink', 'data-book-passage', 'viewBox', 'preserveAspectRatio', 'd', 'x', 'y', 'x1', 'y1', 'x2', 'y2', 'stroke-width', 'encoding', 'display', 'mathvariant'],
            ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto|tel|markview-doc|markview-wikilink):|data:image\/(?:png|jpe?g|gif|webp|avif)[;,]|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i,
            FORBID_TAGS: COMMON_FORBID_TAGS.concat(['video', 'audio', 'button', 'textarea', 'select'])
        },
        discussion: {
            ADD_TAGS: ['details', 'summary', 'canvas', 'button', 'figure', 'figcaption'],
            ADD_ATTR: ['target', 'open', 'class', 'id', 'title', 'alt', 'src', 'href', 'width', 'height', 'viewBox', 'data-kind', 'data-src', 'data-expand', 'data-save', 'data-copy'],
            ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto|tel):|data:image\/(?:png|jpe?g|gif|webp|avif)[;,]|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i,
            FORBID_TAGS: COMMON_FORBID_TAGS
        },
        insight: {
            ADD_TAGS: ['details', 'summary', 'annotation', 'semantics', 'canvas'],
            ADD_ATTR: ['class', 'id', 'style', 'data-chart', 'data-chart-config', 'data-mermaid', 'data-katex', 'aria-hidden', 'target', 'colspan', 'rowspan', 'width', 'height', 'title', 'alt', 'src', 'href', 'open'],
            ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto):|data:image\/(?:png|jpe?g|gif|webp|avif)[;,]|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i,
            FORBID_TAGS: COMMON_FORBID_TAGS
        }
    };

    // A url() may only point inside the document (#fragment, for gradients, filters and markers) or carry a raster picture.
    function urlsAreInline(text) {
        var allowed = true;
        var rest = text.replace(STYLE_URL, function(all, double, single, bare) {
            var target = String(double || single || bare || '').replace(/[\u0000-\u0020]+/g, '');
            if (!(target.charAt(0) === '#' || /^data:image\/(?:png|jpe?g|gif|webp|avif)[;,]/i.test(target))) allowed = false;
            return '';
        });
        return allowed && !/url\(/i.test(rest);
    }

    // `property` and `value` are what the browser's parser reports for one longhand, so escapes and comments are already gone
    // (a custom property is kept as written, which is why it may carry neither). A shorthand that holds var() has no value
    // for its longhands and is dropped with them.
    function isSafeDeclaration(property, value) {
        var name = String(property || '').toLowerCase();
        var text = String(value || '');
        if (!name || !text || text.indexOf('<') >= 0) return false;
        if (name.indexOf('--') === 0) {
            if (/\\|\/\*/.test(text)) return false;
        } else {
            if (!STYLE_PROPERTY_ALLOW.test(name.replace(/^-webkit-/, ''))) return false;
            if (name === 'position' && !/^(?:static|relative)$/i.test(text)) return false;
        }
        return !STYLE_VALUE_UNSAFE.test(text) && urlsAreInline(text);
    }

    function sanitizeStyleAttribute(rawStyle) {
        var holder = cssParserDocument().createElement('div');
        holder.style.cssText = String(rawStyle || '');
        return safeDeclarations(holder.style);
    }

    // The browser's own CSS parser reads every style attribute and the stylesheet Mermaid writes into its SVG, in a document
    // that has no browsing context (its sheets are parsed but never applied and never fetch anything), and only the
    // serialised declarations it reports back are checked and written out. A check on the raw text can be bypassed by CSS
    // escapes (`f\69xed`, `\75rl(`), comments (`position:/**/fixed`) and splitting tricks; the serialised form carries none.
    var cssParserDoc = null;
    var cssCleanStyle = null;
    function cssParserDocument() {
        if (!cssParserDoc) {
            cssParserDoc = global.document.implementation.createHTMLDocument('');
            cssCleanStyle = cssParserDoc.createElement('div').style;
        }
        return cssParserDoc;
    }

    // The comma-separated selectors of a rule, or null when the text cannot be split safely or uses a sibling combinator
    // (`#id ~ p`, `#id + p`), which would reach elements outside the diagram.
    function splitScopedSelectors(text) {
        var parts = [], depth = 0, quote = '', start = 0;
        for (var i = 0; i < text.length; i++) {
            var ch = text.charAt(i);
            if (quote) {
                if (ch === '\\') i++;
                else if (ch === quote) quote = '';
            } else if (ch === '\\') {
                i++;
            } else if (ch === '"' || ch === "'") {
                quote = ch;
            } else if (ch === '(' || ch === '[') {
                depth++;
            } else if (ch === ')' || ch === ']') {
                if (--depth < 0) return null;
            } else if (depth === 0 && ch === ',') {
                parts.push(text.slice(start, i));
                start = i + 1;
            } else if (depth === 0 && (ch === '+' || ch === '~')) {
                return null;
            }
        }
        if (depth !== 0 || quote) return null;
        parts.push(text.slice(start));
        return parts;
    }

    function safeDeclarations(source) {
        if (source.length > MAX_STYLE_DECLARATIONS) return '';
        cssParserDocument();
        var target = cssCleanStyle;
        target.cssText = '';
        for (var i = 0; i < source.length; i++) {
            var property = source[i];
            var value = source.getPropertyValue(property);
            if (isSafeDeclaration(property, value)) target.setProperty(property, value, source.getPropertyPriority(property));
        }
        return target.cssText;
    }

    // Mermaid writes one <style> into every SVG and prefixes each of its rules with the SVG's own id. A stylesheet inside an
    // inline SVG applies to the whole page, so only plain rules whose every selector starts at that id are kept; @import,
    // @font-face, @media and the like (Mermaid 10 writes none) and every unsafe declaration are dropped.
    function sanitizeScopedStylesheet(cssText, scopeId) {
        var doc = cssParserDocument();
        var style = doc.createElement('style');
        style.textContent = String(cssText || '');
        doc.head.appendChild(style);
        var scope = new RegExp('^#' + global.CSS.escape(scopeId) + '(?![\\w-])');
        var rules = [];
        Array.prototype.forEach.call(style.sheet ? style.sheet.cssRules : [], function(rule) {
            if (rule.type !== 1) return;
            var selectors = splitScopedSelectors(rule.selectorText);
            if (!selectors || !selectors.every(function(selector) { return scope.test(selector.trim()); })) return;
            var body = safeDeclarations(rule.style);
            var text = rule.selectorText + '{' + body + '}';
            // A '<' could end the element's raw text when the markup is parsed again, so such a rule is dropped.
            if (body && text.indexOf('<') < 0) rules.push(text);
        });
        style.remove();
        return rules.join('\n');
    }

    function ensureDOMPurifyURIHook(purify) {
        if (!purify || typeof purify.addHook !== 'function' || purify.__markviewURIHookInstalled) return;
        purify.__markviewURIHookInstalled = true;
        purify.addHook('afterSanitizeAttributes', function(node) {
            if (!node || !node.hasAttribute) return;
            URL_ATTRS.forEach(function(attr) {
                if (!node.hasAttribute(attr)) return;
                var val = node.getAttribute(attr).replace(/[\u0000-\u0020]+/g, '');
                if (/^file:/i.test(val) || (/^data:/i.test(val) && !/^data:image\/(?:png|jpe?g|gif|webp|avif)[;,]/i.test(val))) {
                    node.removeAttribute(attr);
                }
            });
            if (node.hasAttribute('style')) {
                var cleanStyle = sanitizeStyleAttribute(node.getAttribute('style'));
                if (cleanStyle) {
                    node.setAttribute('style', cleanStyle);
                } else {
                    node.removeAttribute('style');
                }
            }
        });
    }

    function sanitizeHtml(rawHTML, profile) {
        var purify = global.DOMPurify;
        if (purify && typeof purify.sanitize === 'function') {
            ensureDOMPurifyURIHook(purify);
            var cfg = SANITIZE_PROFILES[profile] || SANITIZE_PROFILES.markdown;
            return purify.sanitize(String(rawHTML || ''), {
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
        return '<pre class="sanitization-error">' + escapeHtml(rawHTML) + '</pre>';
    }

    // Mermaid (securityLevel 'strict') keeps its whole theme in a <style> inside the SVG, so this profile, and only this one,
    // lets <style> through: its text is rebuilt rule by rule by sanitizeScopedStylesheet and the element is removed when
    // nothing safe is left or when the SVG has no id to scope the rules to.
    function sanitizeMermaidSvg(rawSVG) {
        var purify = global.DOMPurify;
        if (purify && typeof purify.sanitize === 'function') {
            ensureDOMPurifyURIHook(purify);
            var body = purify.sanitize(String(rawSVG || ''), {
                USE_PROFILES: { svg: true, svgFilters: true, html: true },
                ADD_TAGS: ['foreignObject'],
                // Mermaid writes its node labels as HTML inside <foreignObject>; DOMPurify 3 keeps only <annotation-xml> as an
                // HTML integration point by default and would empty every label.
                HTML_INTEGRATION_POINTS: { 'foreignobject': true, 'annotation-xml': true },
                ALLOW_DATA_ATTR: false,
                ALLOW_UNKNOWN_PROTOCOLS: false,
                FORBID_TAGS: COMMON_FORBID_TAGS.filter(function(tag) { return tag !== 'style'; }),
                FORBID_ATTR: ['onerror', 'onload', 'onclick', 'onmouseover', 'onmouseenter', 'onmouseleave', 'onfocus', 'onblur'],
                RETURN_DOM: true
            });
            var svg = body.querySelector('svg');
            var scopeId = svg ? svg.getAttribute('id') : '';
            Array.prototype.forEach.call(body.querySelectorAll('style'), function(style) {
                var css = scopeId ? sanitizeScopedStylesheet(style.textContent, scopeId) : '';
                if (css) style.textContent = css; else style.remove();
            });
            return body.innerHTML;
        }
        return '<pre class="sanitization-error">Sanitizer unavailable.</pre>';
    }

    global.mvKit = {
        escapeHtml: escapeHtml,
        escapeAttr: escapeAttr,
        debounce: debounce,
        h: h,
        attachPanZoom: attachPanZoom,
        sanitizeHtml: sanitizeHtml,
        sanitizeMermaidSvg: sanitizeMermaidSvg
    };
    global.mvEscapeHtml = escapeHtml;
    global.mvBridge = mvBridge;
})(typeof window !== 'undefined' ? window : globalThis);
