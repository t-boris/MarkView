        // ============================================================================
        // Markdown extensions used by notes vaults (Obsidian):
        //   [[Note]], [[Note#Heading]], [[#Heading]], [[…|label]], ![[embed]]  → links
        //   $$ … $$ (block) and $ … $ (inline)                                  → KaTeX
        // Both keep their source in data attributes so Turndown (WYSIWYG → markdown,
        // markview-edit.js) writes back exactly what was there.
        // ============================================================================
        (function() {
            if (!md) return;

            function escapeAttr(text) {
                return String(text).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
            }

            // ------------------------------------------------------------ wikilinks
            md.inline.ruler.before('link', 'wikilink', function(state, silent) {
                const src = state.src;
                let pos = state.pos;
                const embed = src.charCodeAt(pos) === 0x21 /* ! */;
                if (embed) pos += 1;
                if (src.charCodeAt(pos) !== 0x5B || src.charCodeAt(pos + 1) !== 0x5B) return false;
                const end = src.indexOf(']]', pos + 2);
                if (end < 0) return false;
                const inner = src.slice(pos + 2, end);
                if (!inner.trim() || inner.indexOf('\n') >= 0 || inner.indexOf('[[') >= 0) return false;
                if (!silent) {
                    const bar = inner.indexOf('|');
                    const target = (bar >= 0 ? inner.slice(0, bar) : inner).trim();
                    const label = bar >= 0 ? inner.slice(bar + 1).trim() : target.replace(/^#/, '').replace(/#/g, ' › ');
                    const token = state.push('wikilink', '', 0);
                    token.meta = { target: target, label: label, embed: embed, raw: src.slice(state.pos, end + 2) };
                }
                state.pos = end + 2;
                return true;
            });
            md.renderer.rules.wikilink = function(tokens, idx) {
                const m = tokens[idx].meta;
                return '<a class="wikilink' + (m.embed ? ' wikilink-embed' : '') + '" href="#" data-wikilink="' + escapeAttr(m.target)
                    + '" data-raw="' + escapeAttr(m.raw) + '">' + (m.embed ? '📎 ' : '') + md.utils.escapeHtml(m.label) + '</a>';
            };

            // ------------------------------------------------------------ math
            function renderMath(tex, display) {
                if (typeof katex === 'undefined') return md.utils.escapeHtml(tex);
                try { return katex.renderToString(tex, { displayMode: display, throwOnError: false }); }
                catch (e) { return md.utils.escapeHtml(tex); }
            }

            md.block.ruler.before('fence', 'math_block', function(state, startLine, endLine, silent) {
                const start = state.bMarks[startLine] + state.tShift[startLine];
                const max = state.eMarks[startLine];
                const first = state.src.slice(start, max);
                if (!first.startsWith('$$')) return false;
                if (silent) return true;
                let content, line = startLine;
                const rest = first.slice(2);
                if (rest.trim().endsWith('$$') && rest.trim().length > 2) {
                    content = rest.trim().slice(0, -2);            // $$ x $$ on one line
                } else {
                    const lines = [rest];
                    let found = false;
                    while (++line < endLine) {
                        const text = state.src.slice(state.bMarks[line] + state.tShift[line], state.eMarks[line]);
                        const close = text.indexOf('$$');
                        if (close >= 0) { lines.push(text.slice(0, close)); found = true; break; }
                        lines.push(text);
                    }
                    if (!found) return false;
                    content = lines.join('\n');
                }
                const token = state.push('math_block', 'div', 0);
                token.block = true;
                token.content = content.trim();
                token.map = [startLine, line + 1];
                state.line = line + 1;
                return true;
            }, { alt: ['paragraph', 'reference', 'blockquote', 'list'] });
            md.renderer.rules.math_block = function(tokens, idx) {
                const t = tokens[idx];
                const lineAttr = t.attrGet('data-line') ? ' data-line="' + t.attrGet('data-line') + '"' : '';
                return '<div class="math-block" contenteditable="false" data-tex="' + escapeAttr(t.content) + '"' + lineAttr + '>'
                    + renderMath(t.content, true) + '</div>\n';
            };

            // $…$: the opening $ is followed by a non-space, the closing one preceded by a
            // non-space and not followed by a digit (so "$5 and $10" stays text).
            md.inline.ruler.after('escape', 'math_inline', function(state, silent) {
                const src = state.src, pos = state.pos;
                if (src.charCodeAt(pos) !== 0x24 /* $ */ || src.charCodeAt(pos + 1) === 0x24) return false;
                const next = src.charAt(pos + 1);
                if (!next || /\s/.test(next)) return false;
                let end = pos + 1;
                while ((end = src.indexOf('$', end)) >= 0) {
                    if (src.charCodeAt(end - 1) !== 0x5C /* \ */) break;
                    end += 1;
                }
                if (end < 0 || /\s/.test(src.charAt(end - 1)) || /\d/.test(src.charAt(end + 1) || '')) return false;
                if (!silent) {
                    const token = state.push('math_inline', 'span', 0);
                    token.content = src.slice(pos + 1, end);
                }
                state.pos = end + 1;
                return true;
            });
            md.renderer.rules.math_inline = function(tokens, idx) {
                const tex = tokens[idx].content;
                return '<span class="math-inline" contenteditable="false" data-tex="' + escapeAttr(tex) + '">' + renderMath(tex, false) + '</span>';
            };

            // ------------------------------------------------------------ clicks
            function normalize(text) { return String(text).replace(/\s+/g, ' ').trim().toLowerCase(); }

            /** Scroll to the heading whose text matches `name` (Obsidian matches by text). */
            window.scrollToHeadingText = function(name, root) {
                const wanted = normalize(name);
                const headings = Array.from((root || document).querySelectorAll('h1, h2, h3, h4, h5, h6'));
                const hit = headings.find(function(h) { return normalize(h.textContent) === wanted; })
                    || headings.find(function(h) { return normalize(h.textContent).indexOf(wanted) === 0; });
                if (hit) hit.scrollIntoView({ behavior: 'smooth', block: 'start' });
                return !!hit;
            };

            document.addEventListener('click', function(e) {
                const link = e.target.closest && e.target.closest('a.wikilink');
                if (!link) return;
                e.preventDefault();
                e.stopPropagation();
                const target = link.getAttribute('data-wikilink') || '';
                const hash = target.indexOf('#');
                const note = hash >= 0 ? target.slice(0, hash).trim() : target.trim();
                const heading = hash >= 0 ? target.slice(hash + 1).trim() : '';
                if (!note) {
                    window.scrollToHeadingText(heading, link.closest('.md-viewer, #editor-rendered') || document);
                    return;
                }
                // Another note: Swift finds it in the vault and opens it at the heading.
                sendToSwift('linkClicked', { href: 'markview-wikilink:' + encodeURIComponent(note)
                    + (heading ? '#' + encodeURIComponent(heading) : '') });
            }, true);
        })();
