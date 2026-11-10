import Foundation

// End-to-End QA (feature end-to-end-qa, REQ-008): what the runner measures on a web page, in the page itself, as evidence for the step-by-step
// review. The assistant sees the screenshot; these numbers tell it what the picture cannot (a font of 9 px, a contrast of 1.9:1, a button
// without a name). Foundation only; the script is checked in a real WKWebView by tools/tests/qa-evidence-web-tests.sh and the reading and
// the summary by tools/tests/qa-review-tests.sh.

struct QAPageEvidence: Codable, Equatable {
    /// How many elements showed one kind of problem, and a few of them described briefly.
    struct Tally: Codable, Equatable {
        var count = 0
        /// At most `QAPageEvidence.maxSamples`: the element's tag, a short visible text, numbers, and its place on the page in CSS px.
        var samples: [String] = []
    }

    /// Text smaller than 12 px.
    var smallText = Tally()
    /// Text whose contrast against its background is below 4.5:1.
    var lowContrast = Tally()
    /// Content cut off by a container that hides its overflow.
    var clipped = Tally()
    /// Buttons, links and fields smaller than 24x24 CSS px (the label of a checkbox or radio button counts as its target).
    var smallTargets = Tally()
    /// The outermost elements that reach past the right edge of the window; only when the page scrolls sideways.
    var beyondRightEdge = Tally()
    /// Buttons, links and fields with no accessible name or label.
    var unlabeledControls = Tally()
    /// Headings that jump down more than one level (an h2 followed by an h4).
    var skippedHeadings = Tally()
    /// How much wider than the window the page is, in CSS px; 0 when it does not scroll sideways.
    var horizontalScrollPixels = 0
    /// The page's own load time as the browser reports it; nil when it reports none.
    var loadMilliseconds: Int? = nil

    static let maxSamples = 5
    /// A sample is at most this long when it is read back, whatever the page sent.
    static let sampleLimit = 120

    var isClean: Bool {
        horizontalScrollPixels == 0 && [smallText, lowContrast, clipped, smallTargets, beyondRightEdge, unlabeledControls, skippedHeadings].allSatisfy { $0.count == 0 }
    }

    /// Compact lines for the prompt; empty when nothing was flagged. The load time is not a problem in itself and is left to the caller.
    var summary: String {
        var lines: [String] = []
        func line(_ title: String, _ tally: Tally) {
            guard tally.count > 0 else { return }
            let samples = tally.samples.isEmpty ? "" : " (e.g. " + tally.samples.joined(separator: "; ") + ")"
            lines.append("- \(title): \(tally.count)\(samples)")
        }
        line("Elements with text smaller than 12 px", smallText)
        line("Elements with text contrast below 4.5:1", lowContrast)
        line("Elements clipped or overflowing their container", clipped)
        line("Click targets smaller than 24x24 px", smallTargets)
        if horizontalScrollPixels > 0 {
            var text = "- The page scrolls sideways: it is \(horizontalScrollPixels) px wider than the window"
            if beyondRightEdge.count > 0 {
                text += "; elements past the right edge: \(beyondRightEdge.count)"
                if !beyondRightEdge.samples.isEmpty { text += " (e.g. " + beyondRightEdge.samples.joined(separator: "; ") + ")" }
            }
            lines.append(text)
        }
        line("Controls without an accessible name or label", unlabeledControls)
        line("Skipped heading levels", skippedHeadings)
        return lines.joined(separator: "\n")
    }

    // MARK: Reading the answer

    /// What the script returned: its JSON text (what `evaluateJavaScript` gives back) or the object already read. Nil when it is not the
    /// JSON the script returns, or when the script failed half way, because a half measurement would read as a clean page.
    static func parse(_ answer: Any?) -> QAPageEvidence? {
        let root: [String: Any]
        if let text = answer as? String {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
            root = object
        } else if let object = answer as? [String: Any] {
            root = object
        } else {
            return nil
        }
        guard (root["qaPageEvidence"] as? NSNumber)?.intValue == 1, (root["failed"] as? Bool) != true else { return nil }

        func whole(_ value: Any?, max: Double) -> Int? {
            guard let number = value as? NSNumber else { return nil }
            return Int(Swift.max(0, Swift.min(number.doubleValue, max)))
        }
        func tally(_ key: String) -> Tally {
            guard let object = root[key] as? [String: Any] else { return Tally() }
            let samples = ((object["samples"] as? [Any]) ?? []).compactMap { item -> String? in
                guard let text = (item as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                return text.count > sampleLimit ? String(text.prefix(sampleLimit - 1)) + "…" : text
            }.prefix(maxSamples)
            return Tally(count: Swift.max(whole(object["count"], max: 1_000_000) ?? 0, samples.count), samples: Array(samples))
        }
        return QAPageEvidence(
            smallText: tally("smallText"), lowContrast: tally("lowContrast"), clipped: tally("clipped"), smallTargets: tally("smallTargets"),
            beyondRightEdge: tally("beyondRightEdge"), unlabeledControls: tally("unlabeledControls"), skippedHeadings: tally("skippedHeadings"),
            horizontalScrollPixels: whole(root["horizontalScrollPixels"], max: 100_000) ?? 0,
            loadMilliseconds: whole(root["loadMilliseconds"], max: 3_600_000).flatMap { $0 > 0 ? $0 : nil })
    }

    // MARK: The measuring script

    /// A JavaScript expression (an immediately invoked function) that measures the current page and returns the result as a JSON string.
    /// It reads layout and computed styles only. It never reads, tests or returns what a person typed: no `value` of any field, no text of
    /// a field or a text area; a sample is the element's tag (and the type of a field), a short visible text taken from the page's own text
    /// nodes outside fields, numbers, and the element's place on the page. Everything is capped (4000 elements, 5 samples, 40 characters).
    static let script = #"""
    (function () {
      var MAX_SAMPLES = 5, MAX_ELEMENTS = 4000, MAX_TEXT = 40;
      var doc = document, root = doc.documentElement, body = doc.body;
      var NO_TEXT = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, INPUT: 1, TEXTAREA: 1, SELECT: 1, OPTION: 1 };
      var CONTROLS = 'a[href],button,input,select,textarea,summary,[role=button],[role=link],[role=checkbox],[role=radio],[role=switch],[role=tab],[role=menuitem],[onclick]';
      var NAMED = 'a[href],button,input,select,textarea,summary,[role=button],[role=link],[role=checkbox],[role=radio],[role=switch],[role=tab],[role=menuitem]';
      var out = {
        qaPageEvidence: 1, failed: false,
        smallText: { count: 0, samples: [] }, lowContrast: { count: 0, samples: [] }, clipped: { count: 0, samples: [] },
        smallTargets: { count: 0, samples: [] }, beyondRightEdge: { count: 0, samples: [] },
        unlabeledControls: { count: 0, samples: [] }, skippedHeadings: { count: 0, samples: [] },
        horizontalScrollPixels: 0, loadMilliseconds: null
      };
      var cache = new Map();

      function r1(v) { return Math.round(v * 10) / 10; }
      function filled(v) { return v != null && /\S/.test(v); }

      // Style, box and opacity of an element, once. Opacity is the product along the ancestors.
      function info(el) {
        var i = cache.get(el);
        if (i) return i;
        var s = getComputedStyle(el), parent = el.parentElement;
        var opacity = parseFloat(s.opacity);
        if (isNaN(opacity)) opacity = 1;
        if (parent) opacity *= info(parent).opacity;
        i = { style: s, rect: el.getBoundingClientRect(), opacity: opacity, visible: null, exceeds: null };
        cache.set(el, i);
        return i;
      }
      function isVisible(el) {
        var i = info(el);
        if (i.visible === null) {
          var s = i.style, r = i.rect;
          i.visible = s.display !== 'none' && s.visibility !== 'hidden' && s.visibility !== 'collapse' && i.opacity > 0 &&
            r.width >= 2 && r.height >= 2 && r.right + window.pageXOffset > 0 && r.bottom + window.pageYOffset > 0;
        }
        return i.visible;
      }

      // The page's own text, never the text of a field: a field's text nodes would be its typed or default value.
      function shortText(el) {
        if (NO_TEXT[el.tagName] || el instanceof SVGElement) return '';
        var text = '';
        (function walk(node) {
          for (var c = node.firstChild; c && text.length < MAX_TEXT * 3; c = c.nextSibling) {
            if (c.nodeType === 3) text += c.nodeValue + ' ';
            else if (c.nodeType === 1 && !NO_TEXT[c.tagName] && !(c instanceof SVGElement)) walk(c);
          }
        })(el);
        text = text.replace(/\s+/g, ' ').replace(/"/g, "'").trim();
        return text.length > MAX_TEXT ? text.slice(0, MAX_TEXT - 1) + '…' : text;
      }
      function ownText(el) {
        if (NO_TEXT[el.tagName]) return false;
        for (var c = el.firstChild; c; c = c.nextSibling) if (c.nodeType === 3 && /\S/.test(c.nodeValue)) return true;
        return false;
      }
      function describe(el, extra) {
        var r = info(el).rect, tag = el.tagName.toLowerCase();
        if (tag === 'input') tag += '[' + (el.type || 'text') + ']';
        var text = shortText(el);
        return tag + (text ? ' "' + text + '"' : '') + (extra ? ' ' + extra : '') +
          ' @' + Math.round(r.left + window.pageXOffset) + ',' + Math.round(r.top + window.pageYOffset);
      }
      function note(bucket, el, extra) {
        var b = out[bucket];
        b.count += 1;
        if (b.samples.length < MAX_SAMPLES) b.samples.push(describe(el, extra));
      }

      // Colour and contrast (WCAG relative luminance). Computed colours arrive as rgb() or rgba(); anything else is not judged.
      function parseColor(text) {
        var m = /^rgba?\(([^)]+)\)$/.exec(String(text).trim());
        if (!m) return null;
        var p = m[1].split(/[\s,\/]+/).filter(Boolean);
        if (p.length < 3) return null;
        var c = { r: parseFloat(p[0]), g: parseFloat(p[1]), b: parseFloat(p[2]), a: 1 };
        if (p.length > 3) { c.a = parseFloat(p[3]); if (/%$/.test(p[3])) c.a /= 100; }
        return isNaN(c.r + c.g + c.b + c.a) ? null : c;
      }
      function mix(top, bottom, alpha) {
        return { r: top.r * alpha + bottom.r * (1 - alpha), g: top.g * alpha + bottom.g * (1 - alpha), b: top.b * alpha + bottom.b * (1 - alpha) };
      }
      // The colour behind an element's text, or null when an image or a gradient makes it unknowable.
      function backdrop(el) {
        var layers = [];
        for (var n = el; n && n.nodeType === 1; n = n.parentElement) {
          var s = info(n).style;
          if (s.backgroundImage && s.backgroundImage !== 'none') return null;
          var c = parseColor(s.backgroundColor);
          if (c === null) return null;
          if (c.a > 0) { layers.push(c); if (c.a >= 1) break; }
        }
        var base = { r: 255, g: 255, b: 255 };
        for (var i = layers.length - 1; i >= 0; i--) base = mix(layers[i], base, layers[i].a);
        return base;
      }
      function luminance(c) {
        function lin(v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
      }
      function contrast(el) {
        var i = info(el), fg = parseColor(i.style.color), bg = backdrop(el);
        if (!fg || !bg) return null;
        var text = mix(fg, bg, fg.a * i.opacity);
        var a = luminance(text), b = luminance(bg);
        return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
      }

      // Does something outside this element, up to the body, cut off or scroll what is wider than the window?
      function clippedByAncestor(el) {
        for (var p = el.parentElement; p && p !== body && p !== root; p = p.parentElement) {
          if (info(p).style.overflowX !== 'visible') return true;
        }
        return false;
      }
      function exceeds(el, vw) {
        if (!el || el === body || el === root) return false;
        var i = info(el);
        if (i.exceeds === null) {
          i.exceeds = i.rect.right + window.pageXOffset > vw + 1 && i.style.position !== 'fixed' && !clippedByAncestor(el);
        }
        return i.exceeds;
      }

      // Does the control have a name a screen reader or a script can find?
      function nameFromElements(ids) {
        var parts = String(ids).split(/\s+/);
        for (var j = 0; j < parts.length; j++) {
          var t = parts[j] && doc.getElementById(parts[j]);
          if (t && (shortText(t) || filled(t.getAttribute('aria-label')))) return true;
        }
        return false;
      }
      function nameFromContent(el) {
        if (shortText(el)) return true;
        var kids = el.querySelectorAll('img[alt],svg title,[aria-label]');
        for (var j = 0; j < kids.length; j++) {
          var k = kids[j];
          if (k.tagName === 'IMG' ? filled(k.getAttribute('alt')) : k.tagName.toLowerCase() === 'title' ? filled(k.textContent) : filled(k.getAttribute('aria-label'))) return true;
        }
        return false;
      }
      // A field is named by a label, or, as browsers do when nothing else is there, by its placeholder.
      function nameOfField(el) {
        var labels = el.labels;
        if (labels) for (var j = 0; j < labels.length; j++) if (shortText(labels[j])) return true;
        return filled(el.getAttribute('placeholder'));
      }
      function hasName(el) {
        if (filled(el.getAttribute('aria-label')) || filled(el.getAttribute('title'))) return true;
        if (filled(el.getAttribute('aria-labelledby')) && nameFromElements(el.getAttribute('aria-labelledby'))) return true;
        var tag = el.tagName;
        if (tag === 'INPUT') {
          var type = (el.type || 'text').toLowerCase();
          if (type === 'submit' || type === 'reset') return true;
          if (type === 'button') return filled(el.getAttribute('value'));
          if (type === 'image') return filled(el.getAttribute('alt'));
          return nameOfField(el);
        }
        if (tag === 'SELECT' || tag === 'TEXTAREA') return nameOfField(el);
        return nameFromContent(el);
      }

      function bigEnough(rect) { return r1(rect.width) >= 24 && r1(rect.height) >= 24; }

      function measure() {
        var vw = root.clientWidth, sx = window.pageXOffset;
        var rootX = info(root).style.overflowX, bodyX = info(body).style.overflowX;
        var viewportX = rootX !== 'visible' ? rootX : bodyX;
        if (viewportX !== 'hidden' && viewportX !== 'clip') {
          var wide = Math.max(root.scrollWidth, body.scrollWidth) - vw;
          if (wide > 1) out.horizontalScrollPixels = wide;
        }
        var list = body.querySelectorAll('*'), n = Math.min(list.length, MAX_ELEMENTS);
        for (var k = 0; k < n; k++) {
          var el = list[k];
          if (el instanceof SVGElement || !isVisible(el)) continue;
          var i = info(el), s = i.style, r = i.rect;

          if (ownText(el)) {
            var size = parseFloat(s.fontSize);
            if (size > 0 && r1(size) < 12) note('smallText', el, r1(size) + 'px');
            var ratio = contrast(el);
            if (ratio !== null && ratio < 4.5) note('lowContrast', el, Math.min(Math.round(ratio * 100) / 100, 4.49) + ':1');
          }

          var cutX = s.overflowX === 'hidden' || s.overflowX === 'clip', cutY = s.overflowY === 'hidden' || s.overflowY === 'clip';
          if ((cutX || cutY) && el.clientWidth > 0 && el.clientHeight > 0 &&
              ((cutX && el.scrollWidth - el.clientWidth > 1) || (cutY && el.scrollHeight - el.clientHeight > 1))) {
            note('clipped', el, 'content ' + el.scrollWidth + 'x' + el.scrollHeight + 'px in ' + el.clientWidth + 'x' + el.clientHeight + 'px');
          }

          if (out.horizontalScrollPixels > 0 && exceeds(el, vw) && !exceeds(el.parentElement, vw)) {
            note('beyondRightEdge', el, 'right edge at ' + Math.round(r.right + sx) + 'px');
          }

          if (el.matches(CONTROLS) && !el.disabled && !(el.tagName === 'A' && s.display === 'inline' && el.parentElement && ownText(el.parentElement))) {
            var big = bigEnough(r);
            if (!big && el.labels) for (var j = 0; j < el.labels.length && !big; j++) big = bigEnough(el.labels[j].getBoundingClientRect());
            if (!big) note('smallTargets', el, r1(r.width) + 'x' + r1(r.height) + 'px');
          }

          if (el.matches(NAMED) && !(el.tagName === 'INPUT' && el.type === 'hidden') && !hasName(el)) note('unlabeledControls', el, '');
        }

        var heads = body.querySelectorAll('h1,h2,h3,h4,h5,h6,[role=heading]'), previous = 0;
        for (var h = 0; h < heads.length && h < MAX_ELEMENTS; h++) {
          var head = heads[h];
          if (!isVisible(head)) continue;
          var level = /^H[1-6]$/.test(head.tagName) ? Number(head.tagName.charAt(1)) : parseInt(head.getAttribute('aria-level'), 10);
          if (!(level >= 1 && level <= 6)) continue;
          if (previous && level > previous + 1) note('skippedHeadings', head, 'after h' + previous);
          previous = level;
        }

        var nav = performance.getEntriesByType && performance.getEntriesByType('navigation')[0], ms = 0;
        if (nav) ms = nav.loadEventEnd > 0 ? nav.loadEventEnd : nav.domContentLoadedEventEnd;
        else if (performance.timing && performance.timing.loadEventEnd > 0) ms = performance.timing.loadEventEnd - performance.timing.navigationStart;
        if (ms > 0) out.loadMilliseconds = Math.round(ms);
      }

      try { if (body) measure(); } catch (e) { out.failed = true; }
      return JSON.stringify(out);
    })()
    """#
}
