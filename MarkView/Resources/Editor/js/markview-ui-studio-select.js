// UI Studio page runtime, part 5 of 6: select mode (hover, selection, instances) and the recording and replay of restoration steps.
(function (A, config) {
  'use strict';
  if (!A.ready) return;   // no configuration, already installed, or no bridge to MarkView (the first part returned early)
  const { describe, instancesOf, notify, realRAF, realSetTimeout, selectorOf, tagLabel, whenIdle } = A;
  Object.assign(A, { redraw, replay, select, setSelecting, showInstances });

  A.host = null;
  var layer = null;
  var hoverBox = null;
  var selectedBox = null;
  var instanceBoxes = [];
  var hovered = null;
  A.selected = null;
  var siblings = [];
  var selecting = false;
  A.pickResolve = null;
  A.captureHidden = false;

  function ensureOverlay() {
    if (A.host && A.host.isConnected) return;
    A.host = document.createElement('markview-studio-overlay');
    A.host.style.cssText = 'position:fixed;inset:0;pointer-events:none;z-index:2147483647;display:block;';
    var root = A.host.attachShadow({ mode: 'closed' });
    layer = document.createElement('div');
    root.appendChild(layer);
    var box = function (css) {
      var div = document.createElement('div');
      div.style.cssText = 'position:fixed;box-sizing:border-box;display:none;pointer-events:none;' + css;
      layer.appendChild(div);
      return div;
    };
    hoverBox = box('border:1px dashed #3794ff;background:rgba(55,148,255,0.12);');
    var label = document.createElement('div');
    label.style.cssText = 'position:absolute;left:-1px;top:-20px;padding:0 6px;font:11px/18px -apple-system,system-ui,sans-serif;color:#fff;' +
      'background:#3794ff;white-space:nowrap;border-radius:3px;max-width:70vw;overflow:hidden;text-overflow:ellipsis;';
    hoverBox.appendChild(label);
    hoverBox.label = label;
    selectedBox = box('border:2px solid #f5a623;background:rgba(245,166,35,0.10);');
    document.documentElement.appendChild(A.host);
  }

  // Named apart from `place`, the scenario's browser location above: both lived in this scope, the variable replaced this
  // function at start, and every redraw threw "place is not a function" (BUG-086).
  function placeBox(div, el) {
    if (!el || !el.isConnected) { div.style.display = 'none'; return; }
    var r = el.getBoundingClientRect();
    div.style.display = A.captureHidden ? 'none' : 'block';
    div.style.left = r.left + 'px';
    div.style.top = r.top + 'px';
    div.style.width = r.width + 'px';
    div.style.height = r.height + 'px';
    if (div.label) div.label.style.top = r.top < 22 ? (r.height + 2) + 'px' : '-20px';
  }

  var scheduled = false;
  function redraw() {
    if (scheduled) return;
    scheduled = true;
    realRAF(function () {
      scheduled = false;
      if (!A.host) return;
      placeBox(hoverBox, selecting ? hovered : null);
      placeBox(selectedBox, A.selected);
      instanceBoxes.forEach(function (div, i) { placeBox(div, siblings[i]); });
    });
  }
  window.addEventListener('scroll', redraw, { capture: true, passive: true });
  window.addEventListener('resize', redraw, { passive: true });

  function showInstances(elements) {
    ensureOverlay();
    instanceBoxes.forEach(function (div) { div.remove(); });
    instanceBoxes = [];
    siblings = elements.filter(function (el) { return el !== A.selected; }).slice(0, 60);
    siblings.forEach(function () {
      var div = document.createElement('div');
      div.style.cssText = 'position:fixed;box-sizing:border-box;display:none;pointer-events:none;border:1px dashed rgba(245,166,35,0.8);';
      layer.appendChild(div);
      instanceBoxes.push(div);
    });
  }

  function select(el) {
    ensureOverlay();
    A.selected = el;
    var description = describe(el);
    showInstances(instancesOf(el, description.source).elements);
    redraw();
    return description;
  }

  function targetOf(event) {
    var path = event.composedPath ? event.composedPath() : [event.target];
    for (var i = 0; i < path.length; i++) {
      var node = path[i];
      if (node && node.nodeType === 1 && node !== A.host) return node;
    }
    return null;
  }

  function swallow(event) {
    if (!selecting) return;
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
  }

  function onMove(event) {
    if (!selecting) return;
    swallow(event);
    var el = targetOf(event);
    if (!el || el === hovered) return;
    hovered = el;
    ensureOverlay();
    var r = el.getBoundingClientRect();
    hoverBox.label.textContent = tagLabel(el) + '  ' + Math.round(r.width) + '×' + Math.round(r.height);
    redraw();
  }

  function onClick(event) {
    if (!selecting) return;
    swallow(event);
    var el = targetOf(event);
    if (!el) return;
    var description = select(el);
    if (A.pickResolve) { var resolve = A.pickResolve; A.pickResolve = null; resolve(description); }
  }

  function onKey(event) {
    if (!selecting) return;
    if (event.key === 'Escape') {
      swallow(event);
      if (A.pickResolve) { var resolve = A.pickResolve; A.pickResolve = null; resolve(null); }
    } else if (event.type === 'keydown' || event.type === 'keypress' || event.type === 'keyup') {
      // Keys must not reach the page's shortcuts while selecting.
      swallow(event);
    }
  }

  ['mousemove', 'mouseover', 'mouseout', 'mouseenter', 'mouseleave', 'pointermove', 'pointerover', 'pointerout', 'pointerenter',
    'pointerleave'].forEach(function (type) { window.addEventListener(type, onMove, true); });
  window.addEventListener('click', onClick, true);
  ['mousedown', 'mouseup', 'pointerdown', 'pointerup', 'dblclick', 'auxclick', 'contextmenu', 'touchstart', 'touchend', 'submit',
    'dragstart', 'focusin'].forEach(function (type) { window.addEventListener(type, swallow, true); });
  ['keydown', 'keypress', 'keyup'].forEach(function (type) { window.addEventListener(type, onKey, true); });

  function setSelecting(on) {
    selecting = !!on;
    if (!selecting) {
      hovered = null;
      if (A.pickResolve) { var resolve = A.pickResolve; A.pickResolve = null; resolve(null); }
    }
    document.documentElement.style.cursor = selecting ? 'crosshair' : '';
    redraw();
    return selecting;
  }

  // MARK: Steps

  // A page loaded while recording records from its start (BUG-071).
  A.recording = !!config.recording;
  var PASSWORD_PLACEHOLDER = 'markview-test-password';

  function recordStep(step) { notify('recorded', JSON.stringify(step)); }

  function actionTarget(el) {
    return el.closest('a,button,[role="button"],[role="link"],[role="tab"],[role="menuitem"],[role="option"],label,summary,input,select,textarea') || el;
  }

  // A click on a label clicks its control as well: only the label's click is a step.
  var labelControl = null;
  window.addEventListener('click', function (event) {
    if (!A.recording || selecting) return;
    var el = targetOf(event);
    if (!el) return;
    var target = actionTarget(el);
    if (labelControl && target === labelControl) { labelControl = null; return; }
    labelControl = target.tagName === 'LABEL' ? target.control : null;
    if (target.matches('input[type="text"],input:not([type]),input[type="email"],input[type="search"],input[type="password"],input[type="number"],textarea,select')) return;
    recordStep({ action: 'click', selector: selectorOf(target) });
  }, true);

  window.addEventListener('change', function (event) {
    if (!A.recording || selecting) return;
    var el = event.target;
    if (!el || !el.matches) return;
    if (el.matches('input[type="checkbox"],input[type="radio"]')) return;
    if (el.matches('input,textarea,select')) {
      var text = el.type === 'password' ? PASSWORD_PLACEHOLDER : String(el.value).slice(0, 2000);
      recordStep({ action: 'type', selector: selectorOf(el), text: text });
    }
  }, true);

  window.addEventListener('keydown', function (event) {
    if (!A.recording || selecting) return;
    if (event.key === 'Enter' || event.key === 'Escape') {
      var el = event.target && event.target.nodeType === 1 ? event.target : document.body;
      if (event.key === 'Enter' && el.matches && el.matches('input,textarea')) {
        var value = el.type === 'password' ? PASSWORD_PLACEHOLDER : String(el.value).slice(0, 2000);
        recordStep({ action: 'type', selector: selectorOf(el), text: value });
      }
      recordStep({ action: 'press', selector: selectorOf(el), text: event.key });
    }
  }, true);

  function sleep(ms) { return new Promise(function (resolve) { realSetTimeout(resolve, ms); }); }

  function waitFor(selector, timeoutMs) {
    var deadline = performance.now() + timeoutMs;
    return new Promise(function (resolve) {
      (function look() {
        var el = null;
        try { el = document.querySelector(selector); } catch (error) { return resolve(null); }
        if (el) return resolve(el);
        if (performance.now() >= deadline) return resolve(null);
        realSetTimeout(look, 50);
      })();
    });
  }

  function clickElement(el) {
    el.scrollIntoView({ block: 'center', inline: 'center' });
    var r = el.getBoundingClientRect();
    var init = { bubbles: true, cancelable: true, composed: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: 0 };
    el.dispatchEvent(new PointerEvent('pointerdown', init));
    el.dispatchEvent(new MouseEvent('mousedown', init));
    if (typeof el.focus === 'function') el.focus({ preventScroll: true });
    el.dispatchEvent(new PointerEvent('pointerup', init));
    el.dispatchEvent(new MouseEvent('mouseup', init));
    el.click();
  }

  function typeInto(el, text) {
    if (typeof el.focus === 'function') el.focus({ preventScroll: true });
    if (el.isContentEditable) {
      el.textContent = text;
    } else {
      var prototype = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
        : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
      var setter = Object.getOwnPropertyDescriptor(prototype, 'value').set;
      setter.call(el, text);
    }
    el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }

  function pressKey(el, key) {
    var init = { key: key, code: key, bubbles: true, cancelable: true, composed: true };
    el.dispatchEvent(new KeyboardEvent('keydown', init));
    el.dispatchEvent(new KeyboardEvent('keyup', init));
    if (key === 'Enter' && el.form && el.matches('input')) {
      if (typeof el.form.requestSubmit === 'function') el.form.requestSubmit(); else el.form.submit();
    }
  }

  function navigateTo(path) {
    var target = new URL(String(path), location.href);
    if (target.origin !== location.origin) throw new Error('A step may only navigate inside the application.');
    // Load the application page normally: server middleware and redirects must run as they do for a real navigation.
    location.assign(target.href);
  }

  async function replay(steps) {
    var wasSelecting = selecting;
    setSelecting(false);
    try {
      for (var i = 0; i < steps.length; i++) {
        var step = steps[i] || {};
        if (step.action === 'wait') { await sleep(Math.min(Math.max(0, step.ms | 0), 10000)); continue; }
        if (step.action === 'navigate') { navigateTo(step.text || '/'); await whenIdle(5000, 200); continue; }
        var el = await waitFor(step.selector, 5000);
        if (!el) return { ok: false, step: i, reason: 'No element matches ' + step.selector + '.' };
        if (step.action === 'click') clickElement(el);
        else if (step.action === 'type') typeInto(el, step.text || '');
        else if (step.action === 'press') pressKey(el, step.text || 'Enter');
        else return { ok: false, step: i, reason: 'Unknown step ' + step.action + '.' };
        await whenIdle(4000, 200);
      }
      return { ok: true };
    } catch (error) {
      return { ok: false, step: i, reason: String((error && error.message) || error) };
    } finally {
      setSelecting(wasSelecting);
    }
  }

  // MARK: Captures
})(window.__markviewStudioParts, __MARKVIEW_STUDIO_CONFIG__);
