/* Book-specific layout. Every emitted PDF page is an already typeset page, never a slice
   through a long document. Native code builds destinations/annotations from these coordinates. */
(() => {
    'use strict';
    const source = document.getElementById('source'), pages = document.getElementById('pages');
    let chapters = [], options = {}, width = 595, height = 842, bodyHeight = 704;
    let current = null, currentTitle = '', warnings = [], aliases = new Map();
    const escape = text => String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    const slug = text => text.toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, '').replace(/ /g, '-');
    const node = (tag, cls, text) => { const n = document.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; };
    const canonical = value => { const u = new URL(value); u.hash = ''; u.search = ''; return decodeURIComponent(u.href); };
    const yieldLayout = () => new Promise(resolve => setTimeout(resolve, 0));
    const aliasKey = (url, anchor = '') => canonical(url) + '#' + anchor;
    function sanitize(root) {
        root.querySelectorAll('script,style,iframe,object,embed,video,audio,link,meta,base,form,button,textarea,select').forEach(n => n.remove());
        root.querySelectorAll('*').forEach(n => {
            for (const a of [...n.attributes]) {
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
    function page(title = currentTitle, cls = '') {
        if (pages.children.length >= 2000) throw Error('This book exceeds 2,000 pages. Choose fewer sources; no pages were truncated.');
        const p = node('section', 'page ' + cls);
        const head = node('div', 'running-head'); head.append(node('span', '', options.title), node('span', '', title));
        const content = node('div', 'page-content');
        const foot = node('div', 'running-foot'); foot.append(node('span', '', options.author || options.title), node('span', 'page-number'));
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
    function prefixThatFits(element, container, test = () => fits(container)) {
        const points = boundaries(element.textContent); let lo = 0, hi = points.length - 1;
        while (lo < hi) {
            const mid = Math.ceil((lo + hi) / 2), candidate = splitAt(element, points[mid])[0];
            container.append(candidate); const good = test(); candidate.remove();
            if (good) lo = mid; else hi = mid - 1;
        }
        return points[lo];
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
            const oversized = remaining.getBoundingClientRect().height > bodyHeight;
            remaining.remove();
            // Move an ordinary block intact before considering a split. Long paragraphs/code
            // still split at real text boundaries, preserving markup and all characters.
            if (current.childNodes.length && !oversized) { page(); await yieldLayout(); continue; }
            const at = prefixThatFits(remaining, current);
            if (at <= 0 || at >= remaining.textContent.length) {
                if (current.childNodes.length) { page(); await yieldLayout(); continue; }
                throw Error('A block cannot fit on a page without clipping. Try a landscape page or simplify an oversized formula/image.');
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
    function configure(o) {
        options = o; width = o.paper === 'a4Landscape' ? 842 : o.paper === 'letter' ? 612 : 595;
        height = o.paper === 'a4Landscape' ? 595 : o.paper === 'letter' ? 792 : 842; bodyHeight = height - 138;
        for (const [key, value] of [['--w',width],['--h',height],['--body-h',bodyHeight]]) document.documentElement.style.setProperty(key, value + 'px');
        source.style.width = (width - 112) + 'px'; document.body.className = o.theme;
    }
    async function prepare(input, o) {
        configure(o); source.replaceChildren(); pages.replaceChildren(); warnings = []; aliases = new Map();
        chapters = input.map((c, index) => {
            const root = node('article'); let html;
            if (c.format === 'markdown') html = md.render(c.text.replace(/^---\s*\n[\s\S]*?\n---\s*\n/, ''));
            else if (c.format === 'html') html = new DOMParser().parseFromString(c.text, 'text/html').body.innerHTML;
            else if (c.format === 'image') html = `<figure><img src="${escape(c.url)}" alt="${escape(c.title)}"><figcaption>${escape(c.title)}</figcaption></figure>`;
            else if (c.format === 'csv' || c.format === 'tsv') html = csv(c.text, c.format === 'csv' ? ',' : '\t');
            else if (c.format === 'code') html = '<pre><code>' + escape(c.text) + '</code></pre>';
            else html = c.text.split(/\n\s*\n/).map(p => '<p>' + escape(p).replace(/\n/g, '<br>') + '</p>').join('');
            root.innerHTML = html; sanitize(root); wrapLooseProse(root);
            for (const link of root.querySelectorAll('a.wikilink-embed')) {
                const target = link.getAttribute('data-wikilink') || '';
                if (/\.(png|jpe?g|gif|webp|svg|tiff?|heic|bmp)$/i.test(target)) {
                    const img = node('img'); img.src = new URL(target, c.url).href; img.alt = link.textContent.replace(/^📎\s*/, ''); link.replaceWith(img);
                }
            }
            root.querySelectorAll('p,li,h1,h2,h3,h4,h5,h6,td,th,blockquote').forEach(el => el.dir = 'auto');
            const first = root.querySelector('h1');
            if (first && first.textContent.trim() === c.title.trim()) first.remove();
            const header = node('header', 'chapter-header'); header.id = c.id;
            header.append(node('div', 'chapter-kicker', String(index + 1).padStart(2, '0')), node('h1', '', c.title));
            const path = node('div', 'chapter-path', c.path); path.setAttribute('data-no-transform', 'true'); header.append(path); root.prepend(header);
            aliases.set(aliasKey(c.url), c.id); aliases.set(aliasKey(c.url, slug(c.title)), c.id);
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
        for (const block of source.querySelectorAll('pre > code.language-mermaid')) {
            const {svg} = await mermaid.render('diagram-' + Math.random().toString(36).slice(2), block.textContent);
            const div = node('div', 'mermaid'); div.innerHTML = svg; block.parentElement.replaceWith(div);
        }
        const assets = [], assetIDs = new Map();
        for (const c of chapters) for (const img of c.root.querySelectorAll('img')) {
            const url = new URL(img.getAttribute('src'), c.url).href;
            let id = assetIDs.get(url);
            if (!id) { id = 'asset-' + assets.length; assetIDs.set(url, id); assets.push({id, url}); }
            img.dataset.asset = id; img.removeAttribute('src');
        }
        await document.fonts.ready;
        return {assets};
    }
    async function assets(values) {
        for (const img of source.querySelectorAll('img[data-asset]')) {
            img.src = values[img.dataset.asset];
            if (!img.src) throw Error('An image was not loaded.');
            await img.decode();
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
        const cover = page('', 'cover'); cover.querySelector('.running-head').remove(); cover.querySelector('.running-foot').remove();
        current.append(node('div','cover-kicker', labels.book), node('h1','', options.title));
        if (options.author) current.append(node('div','author', options.author));
        current.append(node('div','cover-rule'), node('div','edition', labels.edition));
        if (current.scrollHeight > height - 150) throw Error('The cover title is too long for this page. Shorten the title or use a taller page.');
        const outline = [];
        for (const c of chapters) {
            currentTitle = c.root.querySelector('.chapter-header h1').textContent; page(); await yieldLayout();
            const blocks = [...c.root.childNodes];
            for (let i = 0; i < blocks.length; i++) {
                const b = blocks[i];
                if (b.nodeType === 1 && (/^H[1-6]$/.test(b.tagName) || b.classList.contains('chapter-header'))) {
                    const clone = b.cloneNode(true); current.append(clone);
                    const used = current.scrollHeight; const room = bodyHeight - (clone.getBoundingClientRect().bottom - current.getBoundingClientRect().top);
                    const next = blocks.slice(i + 1).find(x => x.nodeType === 1 || x.textContent.trim());
                    const nextHeight = next?.getBoundingClientRect?.().height || 24;
                    const needed = Math.min(nextHeight + 20, bodyHeight / 3);
                    clone.remove(); if ((!fits() || used > bodyHeight || room < needed) && current.children.length) page();
                }
                await flow(b);
            }
            outline.push({id:c.id, title:currentTitle, level:1});
            const headings = [...c.root.querySelectorAll('h1,h2,h3,h4,h5,h6')].filter(h => !h.closest('.chapter-header'));
            const base = Math.min(...headings.map(h => Number(h.tagName.slice(1))), 6);
            for (const h of headings) outline.push({id:h.id, title:h.textContent, level:Number(h.tagName.slice(1)) - base + 2});
        }
        // Pagination of the contents is independent of page numbers: a fixed-width number
        // column reserves five digits before the chapter page indices are known.
        const firstTOC = pages.children.length; currentTitle = labels.contents; page();
        const heading = node('h1','toc-heading',labels.contents); heading.id = 'book-contents'; await flow(heading);
        for (const entry of outline.filter(x => x.level <= 3)) {
            const row = node('a', 'toc-row level-' + entry.level); row.dataset.target = entry.id; row.href = '#' + entry.id;
            row.append(node('span','toc-title',entry.title),node('span','dots'),node('span','toc-number','99999')); await flow(row);
        }
        const tocPages = [...pages.children].slice(firstTOC);
        const insertion = pages.children[1]; for (const p of tocPages) pages.insertBefore(p, insertion);
        const all = [...pages.children];
        all.forEach((p,i) => { const n=p.querySelector('.page-number'); if(n) n.textContent=String(i+1); });
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
        const links = []; let overflow = 0;
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
                    if (el.closest('.katex-mathml')) continue;
                    const r=el.getBoundingClientRect(); if(r.width && (r.right>br.right+2 || r.bottom>br.bottom+2)) overflow++;
                }
            }
        });
        if (overflow) throw Error('The layout contains overflowing content. Try landscape pages; no clipped PDF was saved.');
        source.style.visibility='hidden';
        return {width,height,count:all.length,destinations:[...destinations.values()],links,outline:[{id:'book-contents',title:labels.contents,level:1},...outline],warnings:[...new Set(warnings)]};
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
