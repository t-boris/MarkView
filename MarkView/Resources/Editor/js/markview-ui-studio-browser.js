// UI Studio page runtime, part 2 of 6: the scenario's browser: seeded Math.random and clock, locale, location, permissions, clipboard, camera and microphone, notifications and kept storage.
(function (A, config) {
  'use strict';
  if (!A.ready) return;   // no configuration, already installed, or no bridge to MarkView (the first part returned early)
  const { RealDate, notify, realSetTimeout, report, surface } = A;
  Object.assign(A, { storageEntries });

  var seedState = (config.seed >>> 0) || 1;
  Math.random = function random() {
    seedState = (seedState + 0x6D2B79F5) >>> 0;
    var t = seedState;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };

  if (typeof config.testTime === 'number' && isFinite(config.testTime)) {
    // The clock shows testTime at MarkView's anchor (the real time of the last restore) and runs on across page loads; the
    // development server's clock shares the anchor (DEC-006). Within a page it advances with the monotonic clock.
    var anchor = typeof config.clockAnchor === 'number' && isFinite(config.clockAnchor) ? config.clockAnchor : RealDate.now();
    var startTime = config.testTime + Math.max(0, RealDate.now() - anchor);
    var startPerf = performance.now();
    var studioNow = function () { return Math.floor(startTime + (performance.now() - startPerf)); };
    var StudioDate = function Date() {
      if (!new.target) return new RealDate(studioNow()).toString();
      if (arguments.length === 0) return new RealDate(studioNow());
      var args = Array.prototype.slice.call(arguments);
      return new (Function.prototype.bind.apply(RealDate, [null].concat(args)))();
    };
    StudioDate.prototype = RealDate.prototype;
    RealDate.prototype.constructor = StudioDate;
    StudioDate.now = studioNow;
    StudioDate.parse = RealDate.parse;
    StudioDate.UTC = RealDate.UTC;
    window.Date = StudioDate;
  }

  if (config.locale) {
    var studioLocale = String(config.locale);
    var zone = config.timeZone ? String(config.timeZone) : null;
    var withZone = function (options) { return zone ? Object.assign({ timeZone: zone }, options || {}) : options; };
    try {
      Object.defineProperty(Navigator.prototype, 'language', { get: function () { return studioLocale; }, configurable: true });
      Object.defineProperty(Navigator.prototype, 'languages', { get: function () { return [studioLocale]; }, configurable: true });
    } catch (error) {}
    var wrapIntl = function (name, zoned) {
      var Real = Intl[name];
      if (!Real) return;
      var Wrapped = function (locales, options) {
        return new Real(locales === undefined ? studioLocale : locales, zoned ? withZone(options) : options);
      };
      Wrapped.prototype = Real.prototype;
      Wrapped.supportedLocalesOf = Real.supportedLocalesOf.bind(Real);
      Intl[name] = Wrapped;
    };
    wrapIntl('DateTimeFormat', true);
    ['NumberFormat', 'Collator', 'PluralRules', 'RelativeTimeFormat', 'ListFormat'].forEach(function (name) { wrapIntl(name, false); });
    ['toLocaleString', 'toLocaleDateString', 'toLocaleTimeString'].forEach(function (name) {
      var real = RealDate.prototype[name];
      RealDate.prototype[name] = function (locales, options) { return real.call(this, locales === undefined ? studioLocale : locales, withZone(options)); };
    });
    var realNumberLocale = Number.prototype.toLocaleString;
    Number.prototype.toLocaleString = function (locales, options) { return realNumberLocale.call(this, locales === undefined ? studioLocale : locales, options); };
  }

  // MARK: Browser features (REQ-008)
  //
  // Location, permissions, the clipboard, camera and microphone, and notifications answer from the scenario's browser
  // settings (`config.browser`). The Mac's own are never used: the page gets the scenario's place, a clipboard of its
  // own, a blank test stream and notifications that are listed in Studio. Each use is reported as a `browser` event;
  // clipboard contents never are.

  var browser = config.browser || {};
  var place = browser.location && browser.location.kind === 'place' && isFinite(browser.location.latitude)
    && isFinite(browser.location.longitude) ? browser.location : null;
  var locationKind = place ? 'place' : (browser.location && browser.location.kind === 'unavailable' ? 'unavailable' : 'denied');
  var mediaGranted = browser.media === 'testStream';
  var notificationPermission = browser.notifications === 'granted' || browser.notifications === 'denied' ? browser.notifications : 'default';
  var pageClipboard = typeof browser.clipboardText === 'string' ? browser.clipboardText : '';

  // A use of the same kind is reported once per page; clipboard writes and notifications every time, up to a bound.
  var browserNotes = 0;
  function browserUse(detail, everyTime) {
    if (!everyTime) return report('browser', detail);
    if (browserNotes >= 100) return;
    browserNotes += 1;
    notify('browser', detail);
  }

  function ownValues(object, values) {
    Object.keys(values).forEach(function (name) {
      Object.defineProperty(object, name, { value: values[name], writable: true, enumerable: true, configurable: true });
    });
    return object;
  }
  // An object that passes `instanceof` for the platform's type (its accessors are shadowed by own values).
  function shaped(Type) { return typeof Type === 'function' && Type.prototype ? Object.create(Type.prototype) : {}; }
  function withEvents(object) {
    var events = new EventTarget();
    return ownValues(object, { addEventListener: events.addEventListener.bind(events), removeEventListener: events.removeEventListener.bind(events),
      dispatchEvent: events.dispatchEvent.bind(events) });
  }
  function later(callback) { realSetTimeout(callback, 0); }
  function onNavigator(name, value) {
    try { Object.defineProperty(Navigator.prototype, name, { get: function () { return value; }, enumerable: true, configurable: true }); } catch (error) {}
  }
  function quoted(text, limit) { return JSON.stringify(String(text).slice(0, limit)); }

  // Location: the scenario's place, or PERMISSION_DENIED (1) or POSITION_UNAVAILABLE (2), always asynchronously. The
  // position's timestamp is the session's test clock.
  function positionError(code) {
    return ownValues(shaped(window.GeolocationPositionError), { code: code, PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3,
      message: code === 1 ? 'User denied Geolocation' : 'The position is unavailable (MarkView UI Studio scenario)' });
  }
  function scenarioPosition() {
    var values = { latitude: +place.latitude, longitude: +place.longitude, accuracy: +place.accuracy > 0 ? +place.accuracy : 25,
      altitude: null, altitudeAccuracy: null, heading: null, speed: null };
    var coords = ownValues(shaped(window.GeolocationCoordinates), values);
    ownValues(coords, { toJSON: function () { return Object.assign({}, values); } });
    var position = ownValues(shaped(window.GeolocationPosition), { coords: coords, timestamp: Date.now() });
    return ownValues(position, { toJSON: function () { return { coords: coords.toJSON(), timestamp: position.timestamp }; } });
  }
  function locate(success, failure) {
    browserUse('geolocation: ' + (place ? 'place ' + quoted(place.label || '', 200) : locationKind));
    if (place) {
      success(scenarioPosition());
    } else if (typeof failure === 'function') {
      failure(positionError(locationKind === 'unavailable' ? 2 : 1));
    }
  }
  function needsCallback(method, success) {
    if (typeof success !== 'function') {
      throw new TypeError("Failed to execute '" + method + "' on 'Geolocation': parameter 1 is not a function.");
    }
  }
  var watches = Object.create(null);
  var watchCount = 0;
  onNavigator('geolocation', ownValues(shaped(window.Geolocation), {
    getCurrentPosition: function getCurrentPosition(success, failure) {
      needsCallback('getCurrentPosition', success);
      later(function () { locate(success, failure); });
    },
    // The place does not move: a watch answers once and stays until it is cleared.
    watchPosition: function watchPosition(success, failure) {
      needsCallback('watchPosition', success);
      watchCount += 1;
      var id = watchCount;
      watches[id] = true;
      later(function () { if (watches[id]) locate(success, failure); });
      return id;
    },
    clearWatch: function clearWatch(id) { delete watches[id]; }
  }));

  // Permissions: the states of the scenario for the features it answers; any other name is asked of the browser.
  function permissionState(name) {
    switch (name) {
      case 'geolocation': return locationKind === 'denied' ? 'denied' : 'granted';
      case 'notifications': return notificationPermission === 'default' ? 'prompt' : notificationPermission;
      case 'camera': case 'microphone': return mediaGranted ? 'granted' : 'denied';
      case 'clipboard-read': case 'clipboard-write': return 'granted';
      default: return null;
    }
  }
  var realPermissions = navigator.permissions || null;
  var realQuery = realPermissions && typeof realPermissions.query === 'function' ? realPermissions.query.bind(realPermissions) : null;
  var studioQuery = function query(descriptor) {
    var name = descriptor && descriptor.name !== undefined ? String(descriptor.name) : '';
    var state = permissionState(name);
    if (state === null) {
      return realQuery ? realQuery(descriptor) : Promise.reject(new TypeError("Failed to execute 'query' on 'Permissions': unknown permission name."));
    }
    browserUse('permissions: ' + name + ' is ' + state);
    return Promise.resolve(withEvents(ownValues(shaped(window.PermissionStatus), { name: name, state: state, onchange: null })));
  };
  if (realPermissions) {
    try { Object.defineProperty(realPermissions, 'query', { value: studioQuery, writable: true, configurable: true }); } catch (error) {}
  } else {
    onNavigator('permissions', ownValues(shaped(window.Permissions), { query: studioQuery }));
  }

  // Clipboard: the page has a clipboard of its own that starts with the scenario's text; writes replace it and are
  // reported by size, never reaching the Mac's clipboard.
  function clipboardWritten(text, types) {
    if (text !== null) pageClipboard = text;
    var parts = [];
    if (text !== null) parts.push(text.length + ' chars');
    if (types && types.length) parts.push(types.join(', ').slice(0, 200));
    browserUse('clipboard: write (' + (parts.join(', ') || 'empty') + ')', true);
  }
  function clipboardRead() { browserUse('clipboard: read (' + pageClipboard.length + ' chars)'); }
  onNavigator('clipboard', withEvents(ownValues(shaped(window.Clipboard), {
    readText: function readText() {
      clipboardRead();
      return Promise.resolve(pageClipboard);
    },
    writeText: function writeText(text) {
      clipboardWritten(String(text), null);
      return Promise.resolve();
    },
    read: function read() {
      clipboardRead();
      var blob = new Blob([pageClipboard], { type: 'text/plain' });
      if (typeof ClipboardItem === 'function') return Promise.resolve([new ClipboardItem({ 'text/plain': blob })]);
      return Promise.resolve([{ types: ['text/plain'], presentationStyle: 'unspecified',
        getType: function (type) { return type === 'text/plain' ? Promise.resolve(blob) : Promise.reject(new DOMException('No such type.', 'NotFoundError')); } }]);
    },
    // Never rejects: the page's items are read as far as they can be, and only their sizes and types are reported.
    write: function write(items) {
      var list = [];
      try { list = Array.prototype.slice.call(items || []); } catch (error) {}
      return Promise.all(list.map(function (item) {
        var types = [];
        try { types = Array.prototype.slice.call((item && item.types) || []).map(String); } catch (error) {}
        if (types.indexOf('text/plain') < 0) return { types: types, text: null };
        return Promise.resolve().then(function () { return item.getType('text/plain'); })
          .then(function (blob) { return typeof blob === 'string' ? blob : blob.text(); })
          .then(function (text) { return { types: types, text: String(text) }; }, function () { return { types: types, text: null }; });
      })).then(function (parts) {
        var text = null;
        var types = [];
        parts.forEach(function (part) {
          part.types.forEach(function (type) { if (types.indexOf(type) < 0) types.push(type); });
          if (text === null && part.text !== null) text = part.text;
        });
        clipboardWritten(text, types.filter(function (type) { return type !== 'text/plain'; }));
      });
    }
  })));
  // document.execCommand('copy') and 'cut' (the classic copy of copy-to-clipboard libraries) write to the page's
  // clipboard too: the copy event lets the page set the data, as a real copy does; otherwise the selection is copied.
  var realExecCommand = Document.prototype.execCommand;
  if (realExecCommand) {
    Document.prototype.execCommand = function execCommand(command) {
      var name = String(command).toLowerCase();
      if (name !== 'copy' && name !== 'cut') return realExecCommand.apply(this, arguments);
      var active = document.activeElement;
      var field = active && (active.tagName === 'TEXTAREA' || active.tagName === 'INPUT') && typeof active.selectionStart === 'number' ? active : null;
      var data = null;
      var event = null;
      try { data = new DataTransfer(); event = new ClipboardEvent(name, { bubbles: true, cancelable: true, composed: true, clipboardData: data }); } catch (error) {}
      if (event) (active || document.body || document.documentElement).dispatchEvent(event);
      var text;
      if (event && event.defaultPrevented && data) text = data.getData('text/plain');
      else if (field) text = field.value.slice(field.selectionStart, field.selectionEnd);
      else text = String(window.getSelection ? window.getSelection() : '');
      clipboardWritten(text, null);
      if (name === 'cut' && !(event && event.defaultPrevented) && (field || (active && active.isContentEditable))) realExecCommand.call(this, 'delete');
      return true;
    };
  }

  // Camera and microphone: denied (NotAllowedError) or a test stream: a blank canvas video track and a silent WebAudio
  // track. No device is opened; the devices listed are test devices.
  function dimension(value, fallback) {
    var number = typeof value === 'number' ? value : value && (value.ideal || value.exact || value.max || value.min);
    number = Math.round(+number);
    return number >= 16 && number <= 4096 ? number : fallback;
  }
  function labelled(track, label) {
    try { Object.defineProperty(track, 'label', { value: label, configurable: true }); } catch (error) {}
    return track;
  }
  function testVideoTrack(constraints) {
    var canvas = document.createElement('canvas');
    var wanted = constraints && typeof constraints === 'object' ? constraints : {};
    canvas.width = dimension(wanted.width, 640);
    canvas.height = dimension(wanted.height, 480);
    if (typeof canvas.captureStream !== 'function') return null;
    var context = canvas.getContext('2d');
    var paint = function () { context.fillStyle = '#202124'; context.fillRect(0, 0, canvas.width, canvas.height); };
    paint();
    var track = canvas.captureStream(15).getVideoTracks()[0] || null;
    // A canvas stream makes frames when the canvas is drawn: the same picture is drawn while the track is live.
    (function frame() {
      if (!track || track.readyState === 'ended') return;
      paint();
      realSetTimeout(frame, 250);
    })();
    return track && labelled(track, 'MarkView Test Camera');
  }
  var testAudio = null;
  function testAudioTrack() {
    var Context = window.AudioContext || window.webkitAudioContext;
    if (!Context) return null;
    try {
      testAudio = testAudio || new Context();
      var oscillator = testAudio.createOscillator();
      var silence = testAudio.createGain();
      silence.gain.value = 0;
      var destination = testAudio.createMediaStreamDestination();
      oscillator.connect(silence);
      silence.connect(destination);
      oscillator.start();
      var track = destination.stream.getAudioTracks()[0] || null;
      return track && labelled(track, 'MarkView Test Microphone');
    } catch (error) {
      return null;
    }
  }
  function mediaKinds(video, audio) { return [video ? 'camera' : null, audio ? 'microphone' : null].filter(Boolean).join(' and '); }
  function studioGetUserMedia(constraints) {
    var video = !!(constraints && constraints.video);
    var audio = !!(constraints && constraints.audio);
    if (!video && !audio) return Promise.reject(new TypeError('At least one of audio and video must be requested.'));
    return new Promise(function (resolve, reject) {
      later(function () {
        if (!mediaGranted) {
          browserUse('media: ' + mediaKinds(video, audio) + ' denied');
          return reject(new DOMException('The request is not allowed by the user agent or the platform in the current context, possibly because the user denied permission.', 'NotAllowedError'));
        }
        var tracks = [];
        var missing = [];
        if (video) { var picture = testVideoTrack(constraints.video); if (picture) tracks.push(picture); else missing.push('camera'); }
        if (audio) { var sound = testAudioTrack(); if (sound) tracks.push(sound); else missing.push('microphone'); }
        if (missing.length || typeof MediaStream !== 'function') {
          browserUse('media: test stream unavailable for the ' + (missing.join(' and ') || mediaKinds(video, audio)));
          return reject(new DOMException('The test stream could not be made in this page.', 'NotReadableError'));
        }
        browserUse('media: test stream for the ' + mediaKinds(video, audio));
        resolve(new MediaStream(tracks));
      });
    });
  }
  function testDevice(kind, label, id) {
    var Type = kind === 'audiooutput' ? window.MediaDeviceInfo : (window.InputDeviceInfo || window.MediaDeviceInfo);
    // Without permission a browser lists one device per kind with neither label nor id.
    var values = { deviceId: mediaGranted ? id : '', groupId: mediaGranted ? 'markview-test-devices' : '', kind: kind, label: mediaGranted ? label : '' };
    var device = ownValues(shaped(Type), values);
    ownValues(device, { toJSON: function () { return Object.assign({}, values); } });
    if (kind !== 'audiooutput') ownValues(device, { getCapabilities: function () { return {}; } });
    return device;
  }
  var realMedia = navigator.mediaDevices || null;
  onNavigator('mediaDevices', withEvents(ownValues(shaped(window.MediaDevices), {
    ondevicechange: null,
    getUserMedia: studioGetUserMedia,
    enumerateDevices: function enumerateDevices() {
      browserUse('media: devices listed');
      return Promise.resolve([testDevice('audioinput', 'MarkView Test Microphone', 'markview-test-microphone'),
        testDevice('videoinput', 'MarkView Test Camera', 'markview-test-camera'),
        testDevice('audiooutput', 'MarkView Test Speakers', 'markview-test-speakers')]);
    },
    getSupportedConstraints: function getSupportedConstraints() {
      try { if (realMedia) return realMedia.getSupportedConstraints(); } catch (error) {}
      return { width: true, height: true, aspectRatio: true, frameRate: true, facingMode: true, deviceId: true, groupId: true };
    },
    getDisplayMedia: function getDisplayMedia() {
      return new Promise(function (_, reject) {
        later(function () {
          browserUse('media: screen sharing denied');
          reject(new DOMException('Screen sharing is not simulated by MarkView UI Studio.', 'NotAllowedError'));
        });
      });
    }
  })));
  ['getUserMedia', 'webkitGetUserMedia'].forEach(function (name) {
    if (!(name in navigator)) return;
    onNavigator(name, function (constraints, success, failure) {
      studioGetUserMedia(constraints).then(success, failure);
    });
  });

  // Notifications: the permission is the scenario's; a notification is listed in Studio (title and body) instead of shown.
  var closedNotifications = new WeakSet();
  function fireNotification(notification, type) {
    var event = new Event(type);
    var handler = notification['on' + type];
    if (typeof handler === 'function') { try { handler.call(notification, event); } catch (error) { surface(error); } }
    notification.dispatchEvent(event);
  }
  class StudioNotification extends EventTarget {
    constructor(title, options) {
      super();
      if (arguments.length === 0) throw new TypeError("Failed to construct 'Notification': 1 argument required, but only 0 present.");
      var settings = options || {};
      this.title = String(title);
      this.body = settings.body == null ? '' : String(settings.body);
      this.tag = settings.tag == null ? '' : String(settings.tag);
      this.icon = settings.icon == null ? '' : String(settings.icon);
      this.dir = settings.dir || 'auto';
      this.lang = settings.lang || '';
      this.data = settings.data === undefined ? null : settings.data;
      this.silent = settings.silent == null ? null : !!settings.silent;
      this.requireInteraction = !!settings.requireInteraction;
      this.onclick = null;
      this.onshow = null;
      this.onerror = null;
      this.onclose = null;
      var shown = notificationPermission === 'granted';
      browserUse('notifications: ' + (shown ? 'shown ' : 'not shown (permission ' + notificationPermission + ') ') + quoted(this.title, 200)
        + (this.body ? ' — ' + this.body.slice(0, 500) : ''), true);
      var self = this;
      later(function () { fireNotification(self, shown ? 'show' : 'error'); });
    }
    close() {
      if (closedNotifications.has(this)) return;
      closedNotifications.add(this);
      var self = this;
      later(function () { fireNotification(self, 'close'); });
    }
    static get permission() { return notificationPermission; }
    static get maxActions() { return 0; }
    static requestPermission(callback) {
      browserUse('notifications: permission requested, answered ' + notificationPermission);
      if (typeof callback === 'function') later(function () { callback(notificationPermission); });
      return Promise.resolve(notificationPermission);
    }
  }
  try { Object.defineProperty(window, 'Notification', { value: StudioNotification, writable: true, configurable: true }); } catch (error) {}

  // MARK: Kept browser data (REQ-008)

  // The localStorage entries the person kept are written once per generation, before the application's own scripts:
  // later pages of the same generation keep what the application changed since. A restore empties sessionStorage too,
  // so each generation starts without the marker.
  var KEPT_MARKER = 'markview-ui-studio-kept';
  (function writeKeptStorage() {
    var entries = Array.isArray(config.keptStorage) ? config.keptStorage : [];
    if (!entries.length) return;
    try {
      if (sessionStorage.getItem(KEPT_MARKER) === String(config.generation)) return;
      entries.forEach(function (entry) {
        if (entry && typeof entry.key === 'string' && typeof entry.value === 'string') localStorage.setItem(entry.key, entry.value);
      });
      sessionStorage.setItem(KEPT_MARKER, String(config.generation));
    } catch (error) {}
  })();

  // The page's localStorage, for "Keep this page's cookies and storage": MarkView decides what may be kept.
  function storageEntries() {
    var entries = [];
    try {
      for (var i = 0; i < localStorage.length && entries.length < 500; i++) {
        var key = localStorage.key(i);
        if (key !== null) entries.push({ key: key, value: localStorage.getItem(key) || '' });
      }
    } catch (error) {}
    return { origin: location.origin, entries: entries };
  }

  // MARK: Third-party SDK stand-ins (BUG-103)
})(window.__markviewStudioParts, __MARKVIEW_STUDIO_CONFIG__);
