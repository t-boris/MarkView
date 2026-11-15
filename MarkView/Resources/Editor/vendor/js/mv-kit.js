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

    global.mvKit = {
        escapeHtml: escapeHtml,
        escapeAttr: escapeAttr,
        debounce: debounce,
        h: h,
        attachPanZoom: attachPanZoom
    };
    global.mvEscapeHtml = escapeHtml;
    global.mvBridge = mvBridge;
})(typeof window !== 'undefined' ? window : globalThis);
