/* Book-specific layout. Every emitted PDF page is an already typeset page, never a slice
   through a long document. Native code builds destinations/annotations from these coordinates. */
(() => {
    'use strict';
    const source = document.getElementById('source'), pages = document.getElementById('pages');
    let chapters = [], options = {}, width = 595, height = 842, bodyHeight = 704;
    let current = null, currentTitle = '', warnings = [], aliases = new Map();
    // A single file printed as a document: title page from its front matter, no chapter heading, contents only when long.
    let documentMeta = {title: '', subtitle: '', author: '', date: ''};
    const isDocument = () => options.mode === 'document';
    const escape =text => String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    const slug = text => text.toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, '').replace(/ /g, '-');
    const node = (tag, cls, text) => { const n = document.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; };
    const canonical = value => { const u = new URL(value); u.hash = ''; u.search = ''; return decodeURIComponent(u.href); };
    // Lets the page process its other messages (a cancellation, for one) between two pages. It is a message-channel task and not a
    // timer: WebKit aligns the timers of a page that is not on screen, as this one never is, to a second and then to longer intervals,
    // which turned a document of several hundred pages into minutes of waiting.
    const yieldLayout = (() => {
        const channel = new MessageChannel(), waiting = [];
        channel.port1.onmessage = () => waiting.shift()();
        return () => new Promise(resolve => { waiting.push(resolve); channel.port2.postMessage(0); });
    })();
    const aliasKey = (url, anchor = '') => canonical(url) + '#' + anchor;
    const mathAttributes = ['class','style','aria-hidden','xmlns','width','height','viewbox','preserveaspectratio','d','x','y','x1','y1','x2','y2','stroke-width','encoding','display','mathvariant'];
    // The inline styles KaTeX writes set sizes, offsets, spacing and colours; any other property (display, position, a background image)
    // is dropped, so markup that only claims to be a formula cannot hide, move or spoof text.
    const mathStyleProperties = new Set(['height','width','min-width','top','left','right','bottom','margin-left','margin-right','margin-top','margin-bottom','vertical-align','border-top-width','border-right-width','border-bottom-width','border-left-width','border-color','border-style','color','background-color','padding-left','padding-right','padding-top','padding-bottom']);
    function safeStyle(value) {
        const kept = [];
        for (const declaration of value.split(';')) {
            const at = declaration.indexOf(':');
            if (at < 0) continue;
            const property = declaration.slice(0, at).trim().toLowerCase(), text = declaration.slice(at + 1).trim();
            if (mathStyleProperties.has(property) && /^[-+0-9a-z.%#(), ]+$/i.test(text) && !/url|image|expression|attr|var\(|env\(|transparent/i.test(text)) kept.push(property + ':' + text);
        }
        return kept.join(';');
    }
    function sanitize(root) {
        root.querySelectorAll('script,style,iframe,object,embed,video,audio,link,meta,base,form,button,textarea,select').forEach(n => n.remove());
        root.querySelectorAll('*').forEach(n => {
            // A formula is laid out by inline styles, SVG paths and MathML attributes of the bundled KaTeX: they stay, and nothing
            // that loads a resource or runs script does.
            const inMath = n.closest('.katex,.math-inline,.math-block,.katex-display');
            for (const a of [...n.attributes]) {
                const name = a.name.toLowerCase();
                if (inMath && mathAttributes.includes(name)) {
                    if (name !== 'style') continue;
                    const style = safeStyle(a.value);
                    if (style) n.setAttribute('style', style); else n.removeAttribute('style');
                    continue;
                }
                if (!['id','href','src','alt','title','colspan','rowspan','start','type','checked','class','data-wikilink'].includes(a.name)) n.removeAttribute(a.name);
            }
            if (n.tagName === 'INPUT') { if (n.type !== 'checkbox') n.remove(); else n.disabled = true; }
            for (const key of ['href','src']) {
                const value = n.getAttribute(key) || '';
                if (/^\s*(javascript|vbscript|blob):/i.test(value)) n.removeAttribute(key);
            }
        });
    }
    function wrapLooseProse(root) {
        for (const container of [...root.querySelectorAll('div,section,article,main,blockquote'), root]) {
            if (container.matches('.math-block,.mermaid')) continue;
            let paragraph = null;
            for (const child of [...container.childNodes]) {
                const inline = child.nodeType === 3 || (child.nodeType === 1 && /^(A|SPAN|STRONG|EM|B|I|U|S|CODE|IMG|BR|SMALL|SUP|SUB|MARK)$/.test(child.tagName));
                if (!inline) { paragraph = null; continue; }
                if (!paragraph && child.nodeType === 3 && !child.textContent.trim()) continue;
                if (!paragraph) { paragraph = node('p'); child.before(paragraph); }
                paragraph.append(child);
            }
        }
    }
    function csv(text, delimiter) {
        const rows = []; let row = [], value = '', quoted = false;
        for (let i = 0; i < text.length; i++) {
            const c = text[i];
            if (c === '"') { if (quoted && text[i + 1] === '"') { value += '"'; i++; } else quoted = !quoted; }
            else if (!quoted && (c === delimiter || c === '\n')) { row.push(value); value = ''; if (c === '\n') { rows.push(row); row = []; } }
            else if (c !== '\r' || quoted) value += c;
        }
        if (value || row.length) { row.push(value); rows.push(row); }
        if (quoted) throw Error('A CSV field has an unclosed quotation mark.');
        const table = node('table', 'csv'), head = table.createTHead(), body = table.createTBody();
        rows.forEach((r, i) => { const tr = (i ? body : head).insertRow(); r.forEach(v => tr.append(node(i ? 'td' : 'th', '', v))); });
        return table.outerHTML;
    }
    // The simple `key: value` lines of a YAML front matter; nested values are not needed for a title page.
    // The block between two rules at the very top of a text, when it is front matter: a list of "key: value" lines, comments, list
    // items and indented continuations. A rule, some prose and another rule is a horizontal rule and a paragraph, not front matter.
    function splitFrontMatter(text) {
        const found = /^---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(text);
        if (!found) return null;
        const lines = found[1].split(/\r?\n/);
        if (!lines.some(line => /^[A-Za-z][\w-]*[ \t]*:/.test(line))) return null;
        if (lines.some(line => line.trim() && !/^([A-Za-z][\w-]*[ \t]*:|[ \t]+\S|-[ \t]|#)/.test(line))) return null;
        return {lines, length: found[0].length};
    }
    function frontMatter(text) {
        const block = splitFrontMatter(text), values = {};
        if (!block) return values;
        for (let i = 0; i < block.lines.length; i++) {
            const pair = /^([A-Za-z][\w-]*)[ \t]*:[ \t]*(.*)$/.exec(block.lines[i]);
            if (!pair) continue;
            let value = pair[2].trim();
            // A folded or literal scalar ("title: >-") continues on the indented lines below it.
            if (/^[>|][-+]?$/.test(value)) {
                const parts = [];
                while (i + 1 < block.lines.length && /^[ \t]+\S/.test(block.lines[i + 1])) parts.push(block.lines[++i].trim());
                value = parts.join(' ');
            }
            if (/^(["']).*\1$/.test(value)) value = value.slice(1, -1);
            const key = pair[1].toLowerCase();
            if (value && !(key in values)) values[key] = value;
        }
        return values;
    }
    const withoutFrontMatter = text => { const block = splitFrontMatter(text); return block ? text.slice(block.length) : text; };
    function pictureName(url) {
        if (/^data:/i.test(url)) return 'embedded picture';
        const last = url.split('?')[0].split('/').pop();
        try { return decodeURIComponent(last); } catch { return last; }
    }
    function longDate(value, locale) {
        const day = /^(\d{4})-(\d{2})-(\d{2})/.exec(value || '');
        const date = day ? new Date(Number(day[1]), Number(day[2]) - 1, Number(day[3])) : (value ? null : new Date());
        if (!date || isNaN(date)) return value || '';
        try { return date.toLocaleDateString(locale || undefined, {year: 'numeric', month: 'long', day: 'numeric'}); } catch { return date.toDateString(); }
    }
    function page(title = currentTitle, cls = '') {
        if (pages.children.length >= 2000) throw Error('This book exceeds 2,000 pages. Choose fewer sources; no pages were truncated.');
        const p = node('section', 'page ' + cls);
        const head = node('div', 'running-head'); head.append(node('span', '', options.title), node('span', '', title));
        const content = node('div', 'page-content');
        const foot = node('div', 'running-foot'); foot.append(node('span', '', isDocument() ? (documentMeta.author || documentMeta.date) : (options.author || options.title)), node('span', 'page-number'));
        p.append(head, content, foot); pages.append(p); current = content;
        return p;
    }
    function fits(container = current) { return container.scrollHeight <= bodyHeight + 0.5; }
    function withoutIDs(n) { if (n.nodeType === 1) { n.removeAttribute('id'); n.querySelectorAll('[id]').forEach(x => x.removeAttribute('id')); } return n; }
    function splitAt(element, offset) {
        const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT); let t, remaining = offset;
        while ((t = walker.nextNode())) {
            if (remaining <= t.length) {
                const first = document.createRange(); first.selectNodeContents(element); first.setEnd(t, remaining);
                const rest = document.createRange(); rest.selectNodeContents(element); rest.setStart(t, remaining);
                const a = element.cloneNode(false), b = withoutIDs(element.cloneNode(false));
                a.append(first.cloneContents()); b.append(rest.cloneContents());
                b.querySelectorAll('[id]').forEach(x => { if (a.querySelector('#' + CSS.escape(x.id))) x.removeAttribute('id'); });
                return [a, b];
            }
            remaining -= t.length;
        }
        return [element.cloneNode(true), element.cloneNode(false)];
    }
    function boundaries(text) {
        const out = [0];
        // Word boundaries for prose; per-character boundaries for CJK/very long identifiers.
        const regex = /\S+\s*|\s+/gu; let m;
        while ((m = regex.exec(text))) {
            if (m[0].length > 80) {
                let at = m.index;
                for (const c of m[0]) { at += c.length; out.push(at); }
            } else out.push(m.index + m[0].length);
        }
        return out;
    }
    // The offsets after each line break: a printed program breaks between its lines, not inside one.
    function lineBoundaries(text) {
        const out = [0];
        for (let i = 0; i < text.length; i++) if (text[i] === '\n' && i + 1 < text.length) out.push(i + 1);
        out.push(text.length);
        return out;
    }
    function prefixThatFits(element, container, test = () => fits(container)) {
        const search = points => {
            let lo = 0, hi = points.length - 1;
            while (lo < hi) {
                const mid = Math.ceil((lo + hi) / 2), candidate = splitAt(element, points[mid])[0];
                container.append(candidate); const good = test(); candidate.remove();
                if (good) lo = mid; else hi = mid - 1;
            }
            return points[lo];
        };
        const text = element.textContent;
        // Only when a single line is taller than the room does the block break inside a line.
        const byLine = isDocument() && element.tagName === 'PRE' ? search(lineBoundaries(text)) : 0;
        return byLine > 0 ? byLine : search(boundaries(text));
    }
    async function flow(element, inherited = []) {
        if (element.nodeType === Node.TEXT_NODE) {
            if (!element.textContent.trim()) return;
            element = node('p', '', element.textContent);
        }
        if (element.nodeType !== Node.ELEMENT_NODE) return;
        if (['DIV','SECTION','ARTICLE','MAIN','HEADER','FOOTER'].includes(element.tagName) && !element.classList.contains('chapter-header') && !element.classList.contains('mermaid') && !element.classList.contains('math-block')) {
            const children = [...element.childNodes].filter(x => x.nodeType === 1 || x.textContent.trim());
            const ids = [...inherited, ...(element.id ? [element.id] : [])];
            for (let index=0; index<children.length; index++) await flow(children[index], index === 0 ? ids : []);
            return;
        }
        if (inherited.length) { element = element.cloneNode(true); element.dataset.aliasIds = JSON.stringify(inherited); }
        if (element.tagName === 'TABLE') { await flowTable(element); return; }
        if (element.tagName === 'UL' || element.tagName === 'OL') { await flowList(element); return; }
        let remaining = element.cloneNode(true);
        while (remaining) {
            current.append(remaining);
            if (fits()) return;
            const total = remaining.getBoundingClientRect().height, oversized = total > bodyHeight;
            remaining.remove();
            // Move an ordinary block intact before considering a split. Long paragraphs/code
            // still split at real text boundaries, preserving markup and all characters.
            // A document also splits a long block that would leave a large gap, when enough of it fits (see breakable).
            if (current.childNodes.length && !oversized && !breakable(remaining, total)) { page(); await yieldLayout(); continue; }
            let at = prefixThatFits(remaining, current);
            if (at <= 0 || at >= remaining.textContent.length) {
                if (current.childNodes.length) { page(); await yieldLayout(); continue; }
                throw Error('A block cannot fit on a page without clipping. Try a landscape page or simplify an oversized formula/image.');
            }
            if (isDocument() && current.childNodes.length) {
                // Never leave a single line of a paragraph at the foot of a page or at the head of the next one.
                const adjusted = withoutWidows(remaining, at);
                if (adjusted <= 0) { page(); await yieldLayout(); continue; }
                at = adjusted;
            }
            const [first, rest] = splitAt(remaining, at);
            current.append(first); remaining = rest; remaining.classList.add('continuation'); page(); await yieldLayout();
        }
    }
    async function flowList(list) {
        let count = Number(list.getAttribute('start') || 1), fragment = null;
        for (const item of [...list.children]) {
            if (!fragment || fragment.parentElement !== current) { fragment = list.cloneNode(false); if (list.tagName === 'OL') fragment.start = count; current.append(fragment); }
            let remaining = item.cloneNode(true);
            for (;;) {
                fragment.append(remaining);
                if (fits()) break;
                remaining.remove();
                if (fragment.children.length || current.children.length > 1) {
                    if (!fragment.children.length) fragment.remove();
                    page(); await yieldLayout(); fragment = list.cloneNode(false); if (list.tagName === 'OL') fragment.start = count; current.append(fragment); continue;
                }
                const at = prefixThatFits(remaining, fragment, () => fits());
                if (!at || at >= remaining.textContent.length) throw Error('An oversized list item cannot be laid out without clipping.');
                const [first, rest] = splitAt(remaining, at); fragment.append(first);
                remaining = rest; remaining.classList.add('continuation'); page(); await yieldLayout(); fragment = list.cloneNode(false); current.append(fragment);
            }
            count++;
        }
    }
    async function flowTable(table) {
        if (table.querySelector('[rowspan]:not([rowspan="1"])')) {
            const test = table.cloneNode(true); current.append(test);
            if (fits()) return;
            test.remove(); if (current.children.length) page(); current.append(test);
            if (!fits()) throw Error('A table with merged rows is taller than a page. Split it at the source or choose a larger page.');
            return;
        }
        if (isDocument()) {
            // A table that fits the rest of the page stays whole, and so does a small one that moves to the next page.
            const probe = table.cloneNode(true); current.append(probe);
            const whole = probe.getBoundingClientRect().height, room = fits(); probe.remove();
            if (room || (whole <= bodyHeight * 0.45 && current.children.length)) {
                if (!room) { page(); await yieldLayout(); }
                current.append(table.cloneNode(true));
                return;
            }
        }
        let fragment, body;
        function start() {
            fragment = table.cloneNode(false);
            for (const x of table.children) if (['THEAD','COLGROUP','CAPTION'].includes(x.tagName)) fragment.append(withoutIDs(x.cloneNode(true)));
            body = fragment.createTBody(); current.append(fragment);
        }
        start();
        const rows = [...table.querySelectorAll(':scope > tbody > tr, :scope > tfoot > tr, :scope > tr')];
        for (const original of rows) {
            let row = original.cloneNode(true);
            for (;;) {
                body.append(row);
                if (fits()) break;
                row.remove();
                if (body.children.length || current.children.length > 1) { if (!body.children.length) fragment.remove(); page(); await yieldLayout(); start(); continue; }
                // One exceptionally long row: split EACH cell at a line boundary and preserve
                // the column grid across continuation rows, rather than cropping the table.
                body.append(row);
                const measurements = [...row.cells].map(cell => ({w:cell.getBoundingClientRect().width - 17, html:cell.innerHTML}));
                row.remove();
                const available = bodyHeight - fragment.getBoundingClientRect().height - 38;
                const first = row.cloneNode(false), rest = withoutIDs(row.cloneNode(false)); let progressed = false, hasRest = false;
                [...row.cells].forEach((cell, i) => {
                    const probe = node('div'); probe.style.cssText = `position:absolute;left:-10000px;width:${measurements[i].w}px;font-size:9.5px;line-height:1.5`;
                    source.append(probe); const candidate = node('div'); candidate.innerHTML = measurements[i].html;
                    probe.append(candidate);
                    let a, b;
                    if (probe.getBoundingClientRect().height <= available) { a = candidate; b = node('div'); }
                    else {
                        candidate.remove(); const at = prefixThatFits(candidate, probe, () => probe.getBoundingClientRect().height <= available);
                        if (!at) { probe.remove(); throw Error('A table cell contains an unbreakable object taller than the page.'); }
                        [a, b] = splitAt(candidate, at);
                    }
                    const ca = cell.cloneNode(false), cb = withoutIDs(cell.cloneNode(false)); ca.innerHTML = a.innerHTML; cb.innerHTML = b.innerHTML;
                    progressed ||= !!a.textContent.trim() || !!a.querySelector('img,svg'); hasRest ||= !!b.textContent.trim() || !!b.querySelector('img,svg');
                    first.append(ca); rest.append(cb); probe.remove();
                });
                if (!progressed) throw Error('A table row could not be split safely.');
                body.append(first);
                if (!fits()) throw Error('A split table row still exceeds the page. Try landscape pages.');
                if (!hasRest) break;
                page(); await yieldLayout(); start(); row = rest;
            }
        }
    }
    // A heading, and in a document also a line that introduces what follows ("as in this picture:") and the rule above footnotes.
    function keepsWithNext(el) {
        if (el.nodeType !== 1) return false;
        if (/^H[1-6]$/.test(el.tagName) || el.classList.contains('chapter-header')) return true;
        if (!isDocument()) return false;
        // A lead-in line ends with a colon, or is a bold or italic line on its own (the caption of a table: "**Table 1.2 — Decisions**").
        const leadIn = el.tagName === 'P' && el.textContent.length < 240 && (/[:：]\s*$/.test(el.textContent) || captionLine(el));
        return leadIn || (el.tagName === 'HR' && el.classList.contains('footnotes-sep'));
    }
    function captionLine(el) {
        const parts = [...el.childNodes].filter(x => x.nodeType === 1 || x.textContent.trim());
        return parts.length === 1 && parts[0].nodeType === 1 && ['STRONG', 'B', 'EM', 'I'].includes(parts[0].tagName);
    }
    // In a document a long paragraph, quotation or code block is split instead of moved whole when at least four lines of it fit.
    function breakable(element, total) {
        if (!isDocument() || !['P', 'BLOCKQUOTE', 'PRE'].includes(element.tagName) || total < bodyHeight * 0.2) return false;
        // The page body has a fixed height, so the room is measured from the bottom of what is already on the page.
        const last = current.lastElementChild;
        const used = last ? last.getBoundingClientRect().bottom - current.getBoundingClientRect().top : 0;
        return bodyHeight - used >= 4 * lineHeightOf(element);
    }
    function lineHeightOf(element) {
        current.append(element);
        const value = parseFloat(getComputedStyle(element).lineHeight);
        element.remove();
        return isNaN(value) ? 16 : value;
    }
    function heightOf(element) {
        const probe = element.cloneNode(true); source.append(probe);
        const value = probe.getBoundingClientRect().height; probe.remove();
        return value;
    }
    // The split offset moved back so that the rest keeps at least two lines; 0 when the first part would have fewer than two.
    function withoutWidows(element, at) {
        const lineHeight = lineHeightOf(element), pad = element.tagName === 'P' ? 1 : 14;
        const text = element.textContent, points = element.tagName === 'PRE' ? lineBoundaries(text) : boundaries(text);
        let index = points.indexOf(at);
        if (index < 0) return at;
        for (let guard = 0; guard < 60; guard++) {
            const [first, rest] = splitAt(element, points[index]);
            if (heightOf(first) < 2 * lineHeight + pad) return 0;
            if (heightOf(rest) >= 2 * lineHeight + pad) return points[index];
            index -= element.tagName === 'PRE' ? 1 : 8;
            if (index <= 0) return 0;
        }
        return 0;
    }
    // A diagram is scaled to the page as a whole. Some diagram types (a Sankey diagram, a Gantt chart) are drawn at a fixed size with
    // no viewBox, so a box narrower than the drawing would cut it instead of scaling it, and a drawing may extend past its viewBox:
    // the viewBox is made to hold everything that is drawn. A small diagram keeps (about) its natural size instead of being
    // stretched over the whole page width.
    function fitDiagram(drawing) {
        let box = drawing.viewBox && drawing.viewBox.baseVal;
        const drawn = (() => { try { return drawing.getBBox(); } catch (error) { return null; } })();
        if (!box || !box.width) {
            const w = parseFloat(drawing.getAttribute('width')), h = parseFloat(drawing.getAttribute('height')), fixed = !/%$/.test(drawing.getAttribute('width') || '');
            if (fixed && w > 0 && h > 0) drawing.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
            else if (drawn && drawn.width > 0 && drawn.height > 0) drawing.setAttribute('viewBox', [drawn.x, drawn.y, drawn.width, drawn.height].join(' '));
            else return;
            box = drawing.viewBox.baseVal;
        }
        if (drawn && drawn.width > 0 && drawn.height > 0) {
            const left = Math.min(box.x, drawn.x), top = Math.min(box.y, drawn.y);
            const right = Math.max(box.x + box.width, drawn.x + drawn.width), bottom = Math.max(box.y + box.height, drawn.y + drawn.height);
            if (right - left > box.width + 2 || bottom - top > box.height + 2) drawing.setAttribute('viewBox', [left, top, right - left, bottom - top].join(' '));
        }
        drawing.removeAttribute('height');
        drawing.style.width = Math.min(drawing.viewBox.baseVal.width * 0.85, width - 112) + 'px';
    }
    function configure(o) {
        options = o; width = o.paper === 'a4Landscape' ? 842 : o.paper === 'letter' ? 612 : 595;
        height = o.paper === 'a4Landscape' ? 595 : o.paper === 'letter' ? 792 : 842; bodyHeight = height - 138;
        for (const [key, value] of [['--w',width],['--h',height],['--body-h',bodyHeight]]) document.documentElement.style.setProperty(key, value + 'px');
        source.style.width = (width - 112) + 'px'; document.body.className = o.theme + (o.mode === 'document' ? ' document' : '');
    }
    async function prepare(input, o) {
        configure(o); source.replaceChildren(); pages.replaceChildren(); warnings = []; aliases = new Map();
        chapters = input.map((c, index) => {
            const root = node('article'); let html;
            if (c.format === 'markdown') html = md.render(withoutFrontMatter(c.text));
            else if (c.format === 'html') html = new DOMParser().parseFromString(c.text, 'text/html').body.innerHTML;
            else if (c.format === 'image') html = `<figure><img src="${escape(c.url)}" alt="${escape(c.title)}"><figcaption>${escape(c.title)}</figcaption></figure>`;
            else if (c.format === 'csv' || c.format === 'tsv') html = csv(c.text, c.format === 'csv' ? ',' : '\t');
            else if (c.format === 'code') html = '<pre><code>' + escape(c.text) + '</code></pre>';
            else html = c.text.split(/\n\s*\n/).map(p => '<p>' + escape(p).replace(/\n/g, '<br>') + '</p>').join('');
            root.innerHTML = html; sanitize(root); wrapLooseProse(root);
            for (const link of root.querySelectorAll('a.wikilink-embed')) {
                const target = link.getAttribute('data-wikilink') || '';
                if (/\.(png|jpe?g|gif|webp|svg|tiff?|heic|bmp)$/i.test(target)) {
                    let href = null;
                    try { href = new URL(target, c.url).href; } catch {}
                    if (!href) continue;
                    const img = node('img'); img.src = href; img.alt = link.textContent.replace(/^📎\s*/, ''); link.replaceWith(img);
                }
            }
            root.querySelectorAll('p,li,h1,h2,h3,h4,h5,h6,td,th,blockquote').forEach(el => el.dir = 'auto');
            let header = null;
            if (isDocument()) {
                // The title comes from the front matter, else from a heading that opens the document, else from the file name.
                const meta = c.format === 'markdown' ? frontMatter(c.text) : {};
                const lead = root.firstElementChild, heading = lead && lead.tagName === 'H1' ? lead : null;
                documentMeta = {
                    title: meta.title || (heading && heading.textContent.trim()) || c.title,
                    subtitle: meta.subtitle || meta.description || '',
                    author: meta.author || options.author || '',
                    date: longDate(meta.date, options.locale)
                };
                if (heading && heading.textContent.trim() === documentMeta.title) heading.remove();
                options.title = documentMeta.title;
            } else {
                const first = root.querySelector('h1');
                if (first && first.textContent.trim() === c.title.trim()) first.remove();
                header = node('header', 'chapter-header'); header.id = c.id;
                header.append(node('div', 'chapter-kicker', String(index + 1).padStart(2, '0')), node('h1', '', c.title));
                const path = node('div', 'chapter-path', c.path); path.setAttribute('data-no-transform', 'true'); header.append(path); root.prepend(header);
                aliases.set(aliasKey(c.url), c.id); aliases.set(aliasKey(c.url, slug(c.title)), c.id);
            }
            const used = new Map();
            root.querySelectorAll('h1,h2,h3,h4,h5,h6,[id]').forEach((el, i) => {
                if (el === header) return;
                const old = el.id, base = /^H[1-6]$/.test(el.tagName) ? slug(el.textContent) : old || 'anchor-' + i;
                const n = used.get(base) || 0; used.set(base, n + 1); const anchor = base + (n ? '-' + n : '');
                el.id = c.id + '-' + anchor;
                if (old) aliases.set(aliasKey(c.url, old), el.id);
                aliases.set(aliasKey(c.url, anchor), el.id);
            });
            root.dataset.chapter = c.id; source.append(root);
            return {...c, root};
        });
        // Render diagrams with the same bundled engine as the editor; no network dependency.
        mermaid.initialize({startOnLoad:false, theme:o.theme === 'midnight' ? 'dark' : 'neutral', securityLevel:'strict'});
        // Every diagram puts a <style> element into the page, and WebKit then restyles every element that is displayed: with the
        // document hidden a diagram costs the same in a document of one page and of five hundred (BUG-105).
        const diagrams = [...source.querySelectorAll('pre > code.language-mermaid')];
        if (diagrams.length) source.style.display = 'none';
        try {
            for (const block of diagrams) {
                let svg;
                try { ({svg} = await mermaid.render('diagram-' + Math.random().toString(36).slice(2), block.textContent)); }
                catch (error) {
                    // A document with one broken diagram is still worth printing: its source stays visible where the picture would be.
                    if (!isDocument()) throw error;
                    warnings.push('A diagram could not be drawn and is shown as its source.');
                    continue;
                }
                const div = node('div', 'mermaid'); div.innerHTML = svg; block.parentElement.replaceWith(div);
            }
        } finally { source.style.display = ''; }
        if (isDocument()) for (const drawing of source.querySelectorAll('.mermaid > svg')) fitDiagram(drawing);
        if (isDocument() && window.Prism) {
            for (const code of source.querySelectorAll('pre > code[class*="language-"]')) {
                const language = (/language-([\w+-]+)/.exec(code.className) || [])[1];
                if (language && Prism.languages[language]) Prism.highlightElement(code, false);
            }
        }
        const assets = [], assetIDs = new Map();
        for (const c of chapters) for (const img of c.root.querySelectorAll('img')) {
            let url = null;
            try { url = new URL(img.getAttribute('src'), c.url).href; } catch (error) { if (!isDocument()) throw error; }
            // A picture without a usable address does not stop the printing of a document: a note takes its place.
            if (isDocument() && (!url || !img.getAttribute('src'))) {
                const name = (img.getAttribute('src') || img.getAttribute('alt') || 'picture').slice(0, 60);
                warnings.push('A picture could not be read: ' + name);
                img.replaceWith(node('span', 'missing-image', 'Picture not available: ' + name));
                continue;
            }
            let id = assetIDs.get(url);
            if (!id) { id = 'asset-' + assets.length; assetIDs.set(url, id); assets.push({id, url}); }
            img.dataset.asset = id; img.dataset.name = pictureName(url); img.removeAttribute('src');
        }
        await document.fonts.ready;
        return {assets};
    }
    async function assets(values) {
        // A picture that cannot be read does not stop the printing of a document: a note takes its place.
        const missing = img => {
            const name = img.dataset.name && img.dataset.name !== 'embedded picture' ? img.dataset.name : (img.getAttribute('alt') || 'picture');
            warnings.push('A picture could not be read: ' + name);
            img.replaceWith(node('span', 'missing-image', 'Picture not available: ' + name));
        };
        for (const img of source.querySelectorAll('img[data-asset]')) {
            const value = values[img.dataset.asset];
            if (!value && isDocument()) { missing(img); continue; }
            img.src = value;
            if (!img.src) throw Error('An image was not loaded.');
            try { await img.decode(); } catch (error) { if (isDocument()) { missing(img); continue; } throw error; }
        }
        // One unambiguous island protects the complete nested KaTeX representation.
        for (const math of source.querySelectorAll('.math-inline,.math-block')) {
            const wrapper = node('book-preserve'); math.replaceWith(wrapper); wrapper.append(math);
        }
        await document.fonts.ready;
        return chapters.map(c => ({id:c.id, html:c.root.innerHTML}));
    }
    function setChapter(id, html) {
        const c = chapters.find(x => x.id === id); if (!c) throw Error('Unknown chapter.');
        c.root.innerHTML = html;
    }
    function snapshot() {
        return chapters.map(c => ({id:c.id, html:c.root.innerHTML, text:c.root.textContent, title:c.root.querySelector('.chapter-header h1').textContent}));
    }
    function prosePassages(id) {
        const c = chapters.find(x => x.id === id); if (!c) throw Error('Unknown chapter.');
        return [...c.root.querySelectorAll('p,li,blockquote')]
            .filter(el => !el.closest('table,pre,code,book-preserve,.footnotes,.footnote-item,.chapter-header') && !el.querySelector('p,li,blockquote'))
            .map((el,index) => { const key='p'+index; el.dataset.bookPassage=key; return {id:key,html:el.innerHTML}; });
    }
    function setPassage(chapter, id, html) {
        const c = chapters.find(x => x.id === chapter), el = c?.root.querySelector('[data-book-passage="'+id+'"]');
        if (!el) throw Error('Unknown prose passage.'); el.innerHTML=html;
    }
    function mapLinks() {
        for (const c of chapters) for (const a of c.root.querySelectorAll('a')) {
            let raw = a.getAttribute('data-wikilink') || a.getAttribute('href'); if (!raw) continue;
            try {
                if (a.hasAttribute('data-wikilink')) {
                    const [name, hash = ''] = raw.split('#');
                    const target = name ? chapters.find(x => x.path.replace(/\.[^.]+$/, '').endsWith(name)) : c;
                    if (target) raw = target.url + (hash ? '#' + slug(hash) : '');
                }
                const u = new URL(raw, c.url), anchor = decodeURIComponent(u.hash.slice(1));
                let target = aliases.get(aliasKey(u.href, anchor));
                if (!target && !/\.[a-z0-9]+$/i.test(u.pathname)) {
                    const found = chapters.find(x => canonical(x.url).replace(/\.[^.]+$/, '') === canonical(u.href));
                    if (found) target = aliases.get(aliasKey(found.url, anchor));
                }
                if (target) { a.dataset.target = target; a.setAttribute('href', '#' + target); }
                else if (['http:','https:','mailto:','tel:'].includes(u.protocol)) { a.dataset.external = u.href; a.href = u.href; }
                else { a.removeAttribute('href'); a.classList.add('unresolved'); warnings.push('Link target outside this book: ' + raw); }
            } catch { a.removeAttribute('href'); warnings.push('An invalid source link could not be exported.'); }
        }
    }
    async function layout(labels) {
        await document.fonts.ready;
        // Translated markup still contains the exact same images and IDs.
        for (const img of source.querySelectorAll('img')) if (!img.complete) await img.decode();
        pages.replaceChildren(); current = null; mapLinks();
        const doc = isDocument();
        const cover = page('', doc ? 'cover document-cover' : 'cover'); cover.querySelector('.running-head').remove(); cover.querySelector('.running-foot').remove();
        if (doc) {
            current.append(node('div','cover-kicker', labels.document), node('h1','', documentMeta.title.length > 180 ? documentMeta.title.slice(0, 179).trimEnd() + '…' : documentMeta.title));
            if (documentMeta.subtitle) current.append(node('div','subtitle', documentMeta.subtitle));
            const facts = node('div','cover-facts');
            if (documentMeta.author) facts.append(node('div','author', documentMeta.author));
            if (documentMeta.date) facts.append(node('div','edition', documentMeta.date));
            current.append(node('div','cover-rule'), facts);
            // The title and the subtitle are set in white on the colour band: a long title is set smaller until they fit the band.
            const title = current.querySelector('h1'), last = current.querySelector('.subtitle') || title, band = cover.getBoundingClientRect().top + height * 0.5;
            for (let size = 44; size > 20 && last.getBoundingClientRect().bottom > band - 34; size -= 2) title.style.fontSize = size + 'px';
        } else {
            current.append(node('div','cover-kicker', labels.book), node('h1','', options.title));
            if (options.author) current.append(node('div','author', options.author));
            current.append(node('div','cover-rule'), node('div','edition', labels.edition));
        }
        if (doc ? current.scrollHeight > current.clientHeight + 1 : current.scrollHeight > height - 150) throw Error('The cover title is too long for this page. Shorten the title or use a taller page.');
        const outline = [];
        for (const c of chapters) {
            currentTitle = doc ? documentMeta.title : c.root.querySelector('.chapter-header h1').textContent; page(); await yieldLayout();
            const blocks = [...c.root.childNodes];
            for (let i = 0; i < blocks.length; i++) {
                const b = blocks[i];
                if (keepsWithNext(b)) {
                    const clone = b.cloneNode(true); current.append(clone);
                    const used = current.scrollHeight; const room = bodyHeight - (clone.getBoundingClientRect().bottom - current.getBoundingClientRect().top);
                    const next = blocks.slice(i + 1).find(x => x.nodeType === 1 || x.textContent.trim());
                    const nextHeight = next?.getBoundingClientRect?.().height || 24;
                    // A picture, a diagram or a formula cannot be split, so the heading needs room for all of it; a table that is
                    // printed whole needs room for all of it too.
                    const unsplittable = doc && next && next.nodeType === 1 && (next.matches('.mermaid,figure,img,.math-block') ||
                        (next.tagName === 'P' && next.querySelector('img,svg') && !next.textContent.trim()) ||
                        (next.tagName === 'TABLE' && nextHeight <= bodyHeight * 0.45));
                    const needed = Math.min(nextHeight + 20, unsplittable ? bodyHeight : bodyHeight / 3);
                    clone.remove(); if ((!fits() || used > bodyHeight || room < needed) && current.children.length) page();
                }
                await flow(b);
            }
            if (!doc) outline.push({id:c.id, title:currentTitle, level:1});
            const headings = [...c.root.querySelectorAll('h1,h2,h3,h4,h5,h6')].filter(h => !h.closest('.chapter-header'));
            const base = Math.min(...headings.map(h => Number(h.tagName.slice(1))), 6);
            for (const h of headings) outline.push({id:h.id, title:h.textContent, level:Number(h.tagName.slice(1)) - base + (doc ? 1 : 2)});
        }
        // A short document has no use for a contents page.
        const listed = outline.filter(x => x.level <= 3);
        const withContents = !doc || (listed.length >= 4 && pages.children.length >= 4);
        let contentsPages = 0;
        if (withContents) {
            // Pagination of the contents is independent of page numbers: a fixed-width number
            // column reserves five digits before the chapter page indices are known.
            const firstTOC = pages.children.length; currentTitle = labels.contents; page();
            const heading = node('h1','toc-heading',labels.contents); heading.id = 'book-contents'; await flow(heading);
            for (const entry of listed) {
                const row = node('a', 'toc-row level-' + entry.level); row.dataset.target = entry.id; row.href = '#' + entry.id;
                row.append(node('span','toc-title',entry.title),node('span','dots'),node('span','toc-number','99999')); await flow(row);
            }
            const tocPages = [...pages.children].slice(firstTOC);
            const insertion = pages.children[1]; for (const p of tocPages) pages.insertBefore(p, insertion);
            contentsPages = tocPages.length;
        }
        const all = [...pages.children];
        all.forEach((p,i) => { const n=p.querySelector('.page-number'); if(n) n.textContent = doc ? (i + 1) + ' / ' + all.length : String(i+1); });
        if (doc) {
            // The running head names the section the page belongs to: the first heading on the page, else the one before it.
            let section = '';
            all.forEach((p, i) => {
                const slot = p.querySelector('.running-head span:last-child');
                if (!slot || p.classList.contains('cover')) return;
                if (i <= contentsPages) { slot.textContent = labels.contents; return; }
                const heading = p.querySelector('.page-content h1, .page-content h2');
                if (heading) section = heading.textContent;
                slot.textContent = section;
            });
        }
        const destinations = new Map();
        all.forEach((p,i) => p.querySelectorAll('[id],[data-alias-ids]').forEach(el => {
            const ids = [...(el.id ? [el.id] : []), ...JSON.parse(el.dataset.aliasIds || '[]')];
            const r=el.getBoundingClientRect(), pr=p.getBoundingClientRect();
            for (const id of ids) if (!destinations.has(id)) destinations.set(id,{id,page:i,x:r.left-pr.left,y:r.top-pr.top});
        }));
        for (const a of pages.querySelectorAll('.toc-row')) {
            const target=destinations.get(a.dataset.target); if(!target) throw Error('A contents entry has no destination.');
            a.querySelector('.toc-number').textContent=String(target.page+1);
        }
        const links = []; let overflow = 0, offender = '';
        all.forEach((p,i) => {
            const pr=p.getBoundingClientRect();
            for (const a of p.querySelectorAll('a[data-target],a[data-external]')) for (const r of a.getClientRects()) {
                if(r.width && r.height) links.push({page:i,x:r.left-pr.left,y:r.top-pr.top,w:r.width,h:r.height,target:a.dataset.target||'',url:a.dataset.external||''});
            }
            if (!p.classList.contains('cover')) {
                const body=p.querySelector('.page-content'), br=body.getBoundingClientRect();
                for(const el of body.querySelectorAll('*')) {
                    // KaTeX keeps a clipped MathML copy for accessibility. Its descendants
                    // report their full intrinsic size despite being visually hidden.
                    if (el.closest('.katex .katex-mathml')) continue;
                    // A radical or a stretched arrow is an SVG far wider than its box, cut by its box (overflow: hidden).
                    if (el.closest('.katex svg')) continue;
                    const r=el.getBoundingClientRect();
                    if(r.width && (r.right>br.right+2 || r.bottom>br.bottom+2)) { overflow++; offender ||= el.tagName.toLowerCase() + (el.className && el.className.baseVal === undefined ? '.' + el.className : '') + ' on page ' + (i + 1); }
                }
            }
        });
        if (overflow) throw Error('The layout contains overflowing content (' + offender + '). Try landscape pages; no clipped PDF was saved.');
        source.style.visibility='hidden';
        return {width,height,count:all.length,destinations:[...destinations.values()],links,outline:withContents ? [{id:'book-contents',title:labels.contents,level:1},...outline] : outline,title:options.title,author:options.author||'',warnings:[...new Set(warnings)]};
    }
    function title(value) { options.title = value; }
    function proseWords() {
        let count = 0;
        for (const c of chapters) {
            const clone = c.root.cloneNode(true);
            clone.querySelectorAll('pre,code,svg,math,book-preserve,table,.chapter-path,.chapter-kicker').forEach(n => n.remove());
            count += [...new Intl.Segmenter(undefined,{granularity:'word'}).segment(clone.textContent)].filter(x => x.isWordLike).length;
        }
        return count;
    }
    window.BookPDF = {prepare, assets, setChapter, snapshot, layout, title, proseWords, prosePassages, setPassage};
})();
