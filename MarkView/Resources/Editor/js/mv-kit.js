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

    // Typed JS <-> Swift bridge registry (AR-28)
    var handlers = Object.create(null);
    var knownOutboundTypes = {
        ready: true,
        contentChanged: true,
        headingsExtracted: true,
        scrollPosition: true,
        scrollOffset: true,
        blocksChanged: true,
        cursorInBlock: true,
        linkClicked: true,
        selectionAction: true,
        translateDocument: true,
        structuredSaved: true,
        structuredRevert: true,
        dictationToggle: true,
        dictationSelectLanguage: true,
        insightAction: true,
        codeAction: true,
        researchMapAction: true,
        architectureAction: true,
        editorFontSize: true,
        jsError: true
    };

    var mvBridge = {
        register: function(name, fn) {
            if (typeof name !== 'string' || typeof fn !== 'function') return;
            handlers[name] = fn;
            if (typeof global[name] !== 'function') {
                global[name] = fn;
            }
        },
        dispatch: function(name, args) {
            var fn = handlers[name] || global[name];
            if (typeof fn !== 'function') return undefined;
            return fn.apply(global, Array.isArray(args) ? args : []);
        },
        send: function(type, payload, channel) {
            var handlerName = channel || 'bridge';
            if (typeof type !== 'string' || !type) return false;
            if (global.webkit && global.webkit.messageHandlers && global.webkit.messageHandlers[handlerName]) {
                global.webkit.messageHandlers[handlerName].postMessage({
                    type: type,
                    payload: payload !== undefined ? payload : {},
                    doc: global.mvDocumentId || ''
                });
                return true;
            }
            return false;
        },
        isKnownType: function(type) {
            return Boolean(knownOutboundTypes[type]);
        },
        registeredNames: function() {
            return Object.keys(handlers);
        }
    };

    var DANGEROUS_STYLE_PROPS = /^(?:z-index|content|behavior|-moz-binding)$/i;
    var DANGEROUS_STYLE_VALUES = /url\s*\(|image\s*\(|-webkit-image-set|image-set|expression\s*\(|@import|-moz-binding|javascript:|vbscript:/i;
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

    function sanitizeStyleAttribute(rawStyle) {
        var kept = [];
        String(rawStyle || '').split(';').forEach(function(declaration) {
            var at = declaration.indexOf(':');
            if (at < 0) return;
            var property = declaration.slice(0, at).trim().toLowerCase();
            var value = declaration.slice(at + 1).trim();
            if (!property || !value) return;
            if (DANGEROUS_STYLE_PROPS.test(property)) return;
            if (property === 'position' && /^(?:fixed|sticky)\b/i.test(value)) return;
            if (DANGEROUS_STYLE_VALUES.test(value)) return;
            kept.push(property + ':' + value);
        });
        return kept.join(';');
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

    function sanitizeMermaidSvg(rawSVG) {
        var purify = global.DOMPurify;
        if (purify && typeof purify.sanitize === 'function') {
            ensureDOMPurifyURIHook(purify);
            return purify.sanitize(String(rawSVG || ''), {
                USE_PROFILES: { svg: true, svgFilters: true, html: true },
                ADD_TAGS: ['foreignObject'],
                ALLOW_DATA_ATTR: false,
                ALLOW_UNKNOWN_PROTOCOLS: false,
                FORBID_TAGS: COMMON_FORBID_TAGS,
                FORBID_ATTR: ['onerror', 'onload', 'onclick', 'onmouseover', 'onmouseenter', 'onmouseleave', 'onfocus', 'onblur']
            });
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
