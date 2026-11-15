// Page to Markdown for the browser tab ("Save as Markdown").
// Injected into every page in an isolated content world, so the page's own scripts can neither
// see nor replace it. `markviewPageMarkdown(mode)` returns { title, url, markdown, hasSelection }:
// mode "selection" converts the selected part, "page" the page's main content.
(function () {
  'use strict';
  if (window.markviewPageMarkdown) return;

  // Never content: scripts, embedded documents, form controls, media players.
  var SKIP = {
    SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, IFRAME: 1, FRAME: 1, SVG: 1, CANVAS: 1,
    BUTTON: 1, INPUT: 1, SELECT: 1, TEXTAREA: 1, OBJECT: 1, EMBED: 1, VIDEO: 1, AUDIO: 1,
    MAP: 1, DIALOG: 1, LINK: 1, META: 1, HEAD: 1
  };
  // Site chrome around the content of a whole page (kept when the reader selects it).
  var CHROME = 'nav, aside, footer, form, [role="navigation"], [role="banner"], [role="contentinfo"], ' +
    '[role="complementary"], [aria-hidden="true"]';
  var BLOCK = {
    ADDRESS: 1, ARTICLE: 1, BLOCKQUOTE: 1, DETAILS: 1, DIV: 1, DL: 1, DT: 1, DD: 1, FIELDSET: 1,
    FIGCAPTION: 1, FIGURE: 1, FOOTER: 1, H1: 1, H2: 1, H3: 1, H4: 1, H5: 1, H6: 1, HEADER: 1,
    HR: 1, LI: 1, MAIN: 1, NAV: 1, OL: 1, P: 1, PRE: 1, SECTION: 1, SUMMARY: 1, TABLE: 1,
    TBODY: 1, THEAD: 1, TFOOT: 1, TR: 1, TD: 1, TH: 1, UL: 1, ASIDE: 1, FORM: 1, CAPTION: 1, BODY: 1
  };

  var pageMode = false;
  var root = null;

  function absolute(url) {
    try { return new URL(url, document.baseURI).href; } catch (e) { return url || ''; }
  }

  function escapeText(text) {
    return text.replace(/([\\`*\[\]<])/g, '\\$1');
  }

  function isHidden(el) {
    if (el.hidden) return true;
    if (!el.isConnected) return false;
    var style = window.getComputedStyle(el);
    return style.display === 'none' || style.visibility === 'hidden';
  }

  function skipped(el) {
    if (SKIP[el.tagName]) return true;
    if (isHidden(el)) return true;
    if (pageMode && el !== root) {
      if (el.matches(CHROME)) return true;
      if (el.tagName === 'HEADER' && !el.closest('article, main')) return true;
    }
    return false;
  }

  function wrap(text, mark) {
    var trimmed = text.trim();
    if (!trimmed) return text;
    var lead = text.match(/^\s*/)[0];
    var tail = text.match(/\s*$/)[0];
    return lead + mark + trimmed + mark + tail;
  }

  function inlineCode(text) {
    text = text.replace(/\s+/g, ' ');
    if (!text.trim()) return '';
    var longest = 0;
    (text.match(/`+/g) || []).forEach(function (run) { longest = Math.max(longest, run.length); });
    var fence = new Array(longest + 2).join('`');
    var pad = text.charAt(0) === '`' || text.charAt(text.length - 1) === '`' ? ' ' : '';
    return fence + pad + text + pad + fence;
  }

  function inlineOf(node) {
    var out = '';
    for (var child = node.firstChild; child; child = child.nextSibling) out += inline(child);
    return out;
  }

  function inline(node) {
    if (node.nodeType === 3) return escapeText(node.nodeValue.replace(/\s+/g, ' '));
    if (node.nodeType !== 1 || skipped(node)) return '';
    switch (node.tagName) {
      case 'BR': return '  \n';
      case 'STRONG': case 'B': return wrap(inlineOf(node), '**');
      case 'EM': case 'I': case 'CITE': return wrap(inlineOf(node), '*');
      case 'DEL': case 'S': case 'STRIKE': return wrap(inlineOf(node), '~~');
      case 'CODE': case 'KBD': case 'SAMP': case 'TT': return inlineCode(node.textContent);
      case 'A': {
        var text = inlineOf(node).trim();
        var href = node.getAttribute('href');
        if (!href || /^javascript:/i.test(href)) return text;
        if (!text) return '';
        return '[' + text + '](' + absolute(href).replace(/\)/g, '%29').replace(/ /g, '%20') + ')';
      }
      case 'IMG': {
        var src = node.currentSrc || node.getAttribute('src');
        if (!src || /^data:/i.test(src)) return '';
        return '![' + escapeText(node.getAttribute('alt') || '') + '](' + absolute(src).replace(/ /g, '%20') + ')';
      }
      default:
        if (BLOCK[node.tagName]) {
          var flat = blocksOf(node).replace(/\n+/g, ' ').trim();
          return flat ? ' ' + flat + ' ' : '';
        }
        return inlineOf(node);
    }
  }

  // Block children joined with blank lines; runs of inline content become paragraphs.
  function blocksOf(node) {
    var out = [];
    var buffer = '';
    function flush() {
      var text = buffer.replace(/[ \t]+\n/g, '\n').replace(/\n[ \t]+/g, '\n').replace(/ {2,}/g, ' ').trim();
      if (text) out.push(text);
      buffer = '';
    }
    for (var child = node.firstChild; child; child = child.nextSibling) {
      if (child.nodeType === 1 && BLOCK[child.tagName]) {
        flush();
        if (skipped(child)) continue;
        var text = block(child);
        if (text && text.trim()) out.push(text);
      } else {
        buffer += inline(child);
      }
    }
    flush();
    return out.join('\n\n');
  }

  function codeLanguage(el) {
    var code = el.querySelector('code');
    var classes = ((el.className || '') + ' ' + (code ? code.className || '' : '')).split(/\s+/);
    for (var i = 0; i < classes.length; i++) {
      var match = classes[i].match(/^(?:language|lang|highlight-source)-([\w+#.-]+)$/);
      if (match) return match[1];
    }
    return '';
  }

  function fenced(text, language) {
    text = text.replace(/\n+$/, '');
    var longest = 2;
    (text.match(/`{3,}/g) || []).forEach(function (run) { longest = Math.max(longest, run.length); });
    var fence = new Array(longest + 2).join('`');
    return fence + language + '\n' + text + '\n' + fence;
  }

  function list(el, ordered) {
    var number = parseInt(el.getAttribute('start') || '1', 10);
    if (isNaN(number)) number = 1;
    var items = [];
    for (var child = el.firstElementChild; child; child = child.nextElementSibling) {
      if (child.tagName !== 'LI' || skipped(child)) continue;
      items.push(listItem(child, ordered ? (number++) + '. ' : '- '));
    }
    return items.join('\n');
  }

  function listItem(li, marker) {
    var body = blocksOf(li).trim();
    // A nested list follows its item's text directly, not as a separate paragraph.
    body = body.replace(/\n\n(?=(?:- |\d+\. ))/g, '\n');
    var box = li.querySelector(':scope > input[type="checkbox"], :scope > p > input[type="checkbox"]');
    if (box) body = (box.checked ? '[x] ' : '[ ] ') + body;
    var pad = new Array(marker.length + 1).join(' ');
    return body.split('\n').map(function (line, index) {
      if (index === 0) return marker + line;
      return line ? pad + line : '';
    }).join('\n');
  }

  function tableCells(row) {
    var cells = [];
    for (var cell = row.firstElementChild; cell; cell = cell.nextElementSibling) {
      if (cell.tagName !== 'TD' && cell.tagName !== 'TH') continue;
      cells.push(inline(cell).replace(/\s+/g, ' ').trim().replace(/\|/g, '\\|'));
    }
    return cells;
  }

  function table(el) {
    var rows = Array.prototype.filter.call(el.querySelectorAll('tr'), function (row) {
      return row.closest('table') === el;
    });
    if (!rows.length) return '';
    var grid = rows.map(tableCells).filter(function (cells) { return cells.length; });
    if (!grid.length) return '';
    var width = Math.max.apply(null, grid.map(function (cells) { return cells.length; }));
    grid.forEach(function (cells) { while (cells.length < width) cells.push(''); });
    var lines = ['| ' + grid[0].join(' | ') + ' |', '|' + new Array(width + 1).join(' --- |')];
    grid.slice(1).forEach(function (cells) { lines.push('| ' + cells.join(' | ') + ' |'); });
    var caption = el.querySelector('caption');
    return (caption ? '*' + inline(caption).trim() + '*\n\n' : '') + lines.join('\n');
  }

  function block(el) {
    var tag = el.tagName;
    switch (tag) {
      case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6': {
        var text = inlineOf(el).replace(/\s+/g, ' ').trim();
        return text ? new Array(+tag.charAt(1) + 1).join('#') + ' ' + text : '';
      }
      case 'P': return inlineOf(el).trim();
      case 'PRE': return fenced(el.textContent, codeLanguage(el));
      case 'BLOCKQUOTE':
        return blocksOf(el).split('\n').map(function (line) { return line ? '> ' + line : '>'; }).join('\n');
      case 'UL': return list(el, false);
      case 'OL': return list(el, true);
      case 'LI': return listItem(el, '- ');
      case 'TABLE': return table(el);
      case 'TR': return tableCells(el).join(' | ');
      case 'HR': return '---';
      case 'DT': return '**' + inlineOf(el).trim() + '**';
      case 'DD': return blocksOf(el);
      case 'FIGCAPTION': case 'CAPTION': {
        var caption = inlineOf(el).trim();
        return caption ? '*' + caption + '*' : '';
      }
      case 'SUMMARY': {
        var summary = inlineOf(el).trim();
        return summary ? '**' + summary + '**' : '';
      }
      default: return blocksOf(el);
    }
  }

  function tidy(markdown) {
    return markdown.replace(/ /g, ' ').replace(/[ \t]+$/gm, function (spaces) {
      return spaces === '  ' ? spaces : '';
    }).replace(/\n{3,}/g, '\n\n').trim();
  }

  // The element that holds the page's content: the largest article / main region when it
  // carries a fair share of the text, else the body.
  function contentRoot() {
    var body = document.body;
    if (!body) return document.documentElement;
    var bodyLength = (body.innerText || '').length;
    var best = null;
    var bestLength = 0;
    document.querySelectorAll('article, main, [role="main"]').forEach(function (candidate) {
      var length = (candidate.innerText || '').length;
      if (length > bestLength) { best = candidate; bestLength = length; }
    });
    return best && bestLength > bodyLength * 0.25 ? best : body;
  }

  function selectionMarkdown(selection) {
    var parts = [];
    for (var i = 0; i < selection.rangeCount; i++) {
      var range = selection.getRangeAt(i);
      var ancestor = range.commonAncestorContainer;
      var element = ancestor.nodeType === 1 ? ancestor : ancestor.parentElement;
      var pre = element && element.closest('pre');
      if (pre) {
        parts.push(fenced(range.toString(), codeLanguage(pre)));
        continue;
      }
      var holder = document.createElement('div');
      holder.appendChild(range.cloneContents());
      var listParent = element && element.closest('ul, ol');
      if (listParent && holder.firstElementChild && holder.firstElementChild.tagName === 'LI') {
        var wrapper = document.createElement(listParent.tagName);
        while (holder.firstChild) wrapper.appendChild(holder.firstChild);
        holder.appendChild(wrapper);
      }
      parts.push(blocksOf(holder));
    }
    return parts.join('\n\n');
  }

  window.markviewPageMarkdown = function (mode) {
    var selection = window.getSelection();
    var hasSelection = !!selection && selection.rangeCount > 0 && selection.toString().trim().length > 0;
    var markdown = '';
    try {
      if (mode === 'selection') {
        pageMode = false;
        root = null;
        if (hasSelection) markdown = selectionMarkdown(selection);
      } else {
        pageMode = true;
        root = contentRoot();
        markdown = block(root);
        var title = (document.title || '').trim();
        if (title && !/^# /m.test(markdown)) markdown = '# ' + escapeText(title) + '\n\n' + markdown;
      }
    } finally {
      pageMode = false;
      root = null;
    }
    return {
      title: (document.title || '').trim(),
      url: location.href,
      markdown: tidy(markdown),
      hasSelection: hasSelection
    };
  };
})();
