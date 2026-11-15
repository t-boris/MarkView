// Element picker for the browser tab ("Pick Element"): hover highlights an element, a click
// chooses it, Esc cancels. Injected into every page in an isolated content world.
// `markviewPickElement()` resolves with { rect, html, selector, tag, text, url, title } for the
// chosen element (rect in viewport points), or null when cancelled. `markviewPickCancel()` ends
// a pick, `markviewPickHide()` removes the highlight so a snapshot does not contain it.
(function () {
  'use strict';
  if (window.markviewPickElement) return;

  var overlay = null;
  var label = null;
  var finish = null;

  function ensureOverlay() {
    if (overlay) return;
    overlay = document.createElement('div');
    overlay.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;display:none;' +
      'box-sizing:border-box;border:2px solid #3794ff;background:rgba(55,148,255,0.18);';
    label = document.createElement('div');
    label.style.cssText = 'position:absolute;left:-2px;top:-22px;padding:1px 6px;font:11px/18px ui-monospace,Menlo,monospace;' +
      'color:#fff;background:#3794ff;white-space:nowrap;border-radius:3px;max-width:60vw;overflow:hidden;text-overflow:ellipsis;';
    overlay.appendChild(label);
    document.documentElement.appendChild(overlay);
  }

  function describe(el) {
    var text = el.tagName.toLowerCase();
    if (el.id) text += '#' + el.id;
    var classes = (typeof el.className === 'string' ? el.className : '').trim().split(/\s+/).filter(Boolean).slice(0, 3);
    if (classes.length) text += '.' + classes.join('.');
    return text;
  }

  // A short CSS path an agent can search for: stops at an id, at most five levels.
  function selectorOf(el) {
    var parts = [];
    for (var node = el; node && node.nodeType === 1 && parts.length < 5; node = node.parentElement) {
      var part = node.tagName.toLowerCase();
      if (node.id) { parts.unshift(part + '#' + node.id); break; }
      var classes = (typeof node.className === 'string' ? node.className : '').trim().split(/\s+/).filter(Boolean).slice(0, 2);
      if (classes.length) part += '.' + classes.join('.');
      parts.unshift(part);
    }
    return parts.join(' > ');
  }

  function place(el) {
    ensureOverlay();
    var r = el.getBoundingClientRect();
    overlay.style.display = 'block';
    overlay.style.left = r.left + 'px';
    overlay.style.top = r.top + 'px';
    overlay.style.width = r.width + 'px';
    overlay.style.height = r.height + 'px';
    label.textContent = describe(el) + '  ' + Math.round(r.width) + '×' + Math.round(r.height);
    label.style.top = r.top < 24 ? (r.height + 2) + 'px' : '-22px';
  }

  function targetAt(event) {
    var el = event.target;
    return el && el.nodeType === 1 && el !== overlay && el !== label ? el : null;
  }

  window.markviewPickHide = function () { if (overlay) overlay.style.display = 'none'; };

  window.markviewPickCancel = function () { if (finish) finish(null); };

  window.markviewPickElement = function () {
    if (finish) finish(null);
    return new Promise(function (resolve) {
      var previousCursor = document.documentElement.style.cursor;
      function onMove(event) { var el = targetAt(event); if (el) place(el); }
      function onClick(event) {
        event.preventDefault();
        event.stopPropagation();
        event.stopImmediatePropagation();
        var el = targetAt(event);
        if (!el) return;
        var r = el.getBoundingClientRect();
        done({
          rect: { x: r.left, y: r.top, width: r.width, height: r.height },
          html: el.outerHTML,
          selector: selectorOf(el),
          tag: describe(el),
          text: (el.innerText || '').trim().slice(0, 300),
          url: location.href,
          title: document.title
        });
      }
      // The page must not see the pick: mouse and pointer events are swallowed while it runs.
      function swallow(event) { event.preventDefault(); event.stopPropagation(); event.stopImmediatePropagation(); }
      function onKey(event) {
        if (event.key === 'Escape') { swallow(event); done(null); }
      }
      function done(value) {
        ['mousemove', 'mouseover'].forEach(function (t) { document.removeEventListener(t, onMove, true); });
        document.removeEventListener('click', onClick, true);
        ['mousedown', 'mouseup', 'pointerdown', 'pointerup', 'auxclick', 'contextmenu'].forEach(function (t) {
          document.removeEventListener(t, swallow, true);
        });
        document.removeEventListener('keydown', onKey, true);
        document.documentElement.style.cursor = previousCursor;
        window.markviewPickHide();
        finish = null;
        resolve(value);
      }
      finish = done;
      ['mousemove', 'mouseover'].forEach(function (t) { document.addEventListener(t, onMove, true); });
      document.addEventListener('click', onClick, true);
      ['mousedown', 'mouseup', 'pointerdown', 'pointerup', 'auxclick', 'contextmenu'].forEach(function (t) {
        document.addEventListener(t, swallow, true);
      });
      document.addEventListener('keydown', onKey, true);
      document.documentElement.style.cursor = 'crosshair';
    });
  };
})();
