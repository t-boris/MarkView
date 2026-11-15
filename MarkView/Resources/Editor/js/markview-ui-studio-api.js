// UI Studio page runtime, part 6 of 6: capture preparation and the window.__markviewStudio API.
(function (A, config) {
  'use strict';
  if (!A.ready) return;   // no configuration, already installed, or no bridge to MarkView (the first part returned early)
  const {
    deliverChannel, describe, overlayText, realRAF, redraw, replay, select, setSelecting, showInstances,
    similarElements, storageEntries, whenIdle
  } = A;

  var freezeStyle = null;
  async function prepareCapture() {
    A.captureHidden = true;
    if (A.host) A.host.style.display = 'none';
    if (!freezeStyle) {
      freezeStyle = document.createElement('style');
      freezeStyle.textContent = '*,*::before,*::after{animation-play-state:paused!important;animation-delay:0s!important;' +
        'transition:none!important;caret-color:transparent!important;scroll-behavior:auto!important}';
      document.documentElement.appendChild(freezeStyle);
    }
    if (document.getAnimations) {
      document.getAnimations().forEach(function (animation) {
        try { animation.currentTime = 0; animation.pause(); } catch (error) {}
      });
    }
    try { await document.fonts.ready; } catch (error) {}
    await new Promise(function (resolve) { realRAF(function () { realRAF(resolve); }); });
    return rendering();
  }

  function finishCapture() {
    A.captureHidden = false;
    if (A.host) A.host.style.display = 'block';
    if (freezeStyle) { freezeStyle.remove(); freezeStyle = null; }
    if (document.getAnimations) document.getAnimations().forEach(function (animation) { try { animation.play(); } catch (error) {} });
    redraw();
    return true;
  }

  function rendering() {
    var fonts = [];
    try {
      document.fonts.forEach(function (face) {
        if (face.status === 'loaded') {
          var family = face.family.replace(/^["']|["']$/g, '');
          if (fonts.indexOf(family) < 0) fonts.push(family);
        }
      });
    } catch (error) {}
    var options = new Intl.DateTimeFormat().resolvedOptions();
    var engine = /AppleWebKit\/([\d.]+)/.exec(navigator.userAgent);
    return {
      engine: engine ? 'WebKit ' + engine[1] : navigator.userAgent.slice(0, 120),
      width: innerWidth, height: innerHeight, devicePixelRatio: devicePixelRatio,
      fonts: fonts.sort(), locale: options.locale, timeZone: options.timeZone,
      colorScheme: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
    };
  }

  // MARK: API for MarkView

  var api = {
    version: 1,
    generation: config.generation,
    setSelecting: setSelecting,
    // Resolves with the element the person clicks in select mode; null when select mode ends or Escape is pressed.
    pick: function () {
      if (A.pickResolve) { var previous = A.pickResolve; A.pickResolve = null; previous(null); }
      setSelecting(true);
      return new Promise(function (resolve) { A.pickResolve = resolve; });
    },
    selected: function () { return A.selected && A.selected.isConnected ? describe(A.selected) : null; },
    parent: function () {
      if (!A.selected || !A.selected.isConnected) return null;
      var parent = A.selected.parentElement;
      if (!parent || parent === document.documentElement) return describe(A.selected);
      return select(parent);
    },
    child: function () {
      if (!A.selected || !A.selected.isConnected || !A.selected.firstElementChild) return null;
      return select(A.selected.firstElementChild);
    },
    clear: function () { A.selected = null; showInstances([]); redraw(); return true; },
    // The elements now matching a selector, described (to revalidate a selection after a change).
    candidates: function (selector) {
      var list = [];
      try { list = Array.prototype.slice.call(document.querySelectorAll(selector), 0, 50); } catch (error) { return []; }
      return list.map(describe);
    },
    selectMatching: function (selector, index) {
      var list = [];
      try { list = document.querySelectorAll(selector); } catch (error) { return null; }
      var el = list[index | 0] || list[0];
      return el ? select(el) : null;
    },
    // Elements that may be the selected one wherever they are now (BUG-068): the same tag and, when known, the same
    // component; otherwise sharing a class or the text. MarkView decides which of them, if any, is the same element.
    similar: function (fingerprint) { return similarElements(fingerprint).map(describe); },
    selectSimilar: function (fingerprint, index) {
      var el = similarElements(fingerprint)[index | 0];
      return el ? select(el) : null;
    },
    setRecording: function (on) { A.recording = !!on; return A.recording; },
    replay: replay,
    whenIdle: whenIdle,
    typedSinceRoute: function () { return A.typedOn === location.pathname + location.search; },
    prepareCapture: prepareCapture,
    finishCapture: finishCapture,
    rendering: rendering,
    storage: storageEntries,
    // Frames MarkView pushes to a simulated WebSocket or EventSource (REQ-015).
    deliver: deliverChannel,
    state: function () {
      return { pending: A.pending, loaded: A.loaded, buildError: overlayText().slice(0, 8000), route: location.pathname + location.search + location.hash,
        title: document.title };
    }
  };
  Object.defineProperty(window, '__markviewStudio', { value: Object.freeze(api), enumerable: false, configurable: false, writable: false });
})(window.__markviewStudioParts, __MARKVIEW_STUDIO_CONFIG__);
delete window.__markviewStudioParts;
