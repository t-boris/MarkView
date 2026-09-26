        // MARKDOWN RENDERING
        // ============================================================================

        function resolveLocalURLs() {
            if (!state.documentBaseURL) return;

            // Resolve relative image src to absolute file:// URLs
            DOM.rendered.querySelectorAll('img').forEach(img => {
                const src = img.getAttribute('src');
                if (!src || src.startsWith('http://') || src.startsWith('https://')
                    || src.startsWith('file://') || src.startsWith('data:')) return;
                try {
                    img.setAttribute('src', new URL(src, state.documentBaseURL).href);
                } catch (e) {}
            });

            // Resolve relative link hrefs (skip anchors)
            DOM.rendered.querySelectorAll('a').forEach(a => {
                const href = a.getAttribute('href');
                if (!href || href.startsWith('#') || href.startsWith('http://') || href.startsWith('https://')
                    || href.startsWith('file://') || href.startsWith('mailto:') || href.startsWith('data:')) return;
                try {
                    a.setAttribute('href', new URL(href, state.documentBaseURL).href);
                } catch (e) {}
            });
        }

        function renderMarkdown() {
            if (state.isRendering) return;
            state.isRendering = true;

            try {
                const markdown = DOM.editor.value;
                state.markdown = markdown;

                // Extract YAML frontmatter if present
                let frontmatter = null;
                let contentMd = markdown;
                const fmMatch = markdown.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
                if (fmMatch) {
                    frontmatter = fmMatch[1];
                    contentMd = fmMatch[2];
                }

                // Render markdown to HTML
                let html;
                if (md) {
                    const offset = fmMatch ? markdown.slice(0, markdown.length - contentMd.length).split('\n').length - 1 : 0;
                    const env = {};
                    const tokens = md.parse(contentMd, env);
                    tokens.forEach(function(t) {
                        if (t.map && t.block && t.nesting >= 0) t.attrSet('data-line', String(t.map[0] + 1 + offset));
                    });
                    html = md.renderer.render(tokens, md.options, env);
                } else {
                    // Fallback when markdown-it is unavailable
                    html = '<pre style="white-space: pre-wrap; word-break: break-word;">'
                        + markdown.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
                        + '</pre>';
                }

                // Frontmatter panel (collapsible)
                let fmPanel = '';
                if (frontmatter) {
                    const lines = frontmatter.split('\n').filter(l => l.trim());
                    let rows = '';
                    lines.forEach(line => {
                        const colonIdx = line.indexOf(':');
                        if (colonIdx > 0) {
                            const key = line.substring(0, colonIdx).trim();
                            let val = line.substring(colonIdx + 1).trim();
                            // Color-code some values
                            if (val === 'active') val = '<span style="color:#4ec9b0">●</span> ' + val;
                            else if (val === 'deprecated') val = '<span style="color:#f44747">●</span> ' + val;
                            else if (val === 'high') val = '<span style="color:#4ec9b0">▲</span> ' + val;
                            else if (val === 'low') val = '<span style="color:#ce9178">▼</span> ' + val;
                            // Arrays
                            if (val.startsWith('[') && val.endsWith(']')) {
                                const items = val.slice(1,-1).split(',').map(s => s.trim()).filter(Boolean);
                                val = items.map(i => '<span style="background:var(--bg-tertiary);padding:1px 5px;border-radius:3px;font-size:10px;margin:1px;">' + i + '</span>').join(' ');
                            }
                            rows += '<tr><td style="padding:2px 8px;color:#808080;font-size:10px;white-space:nowrap;vertical-align:top;">' + key + '</td><td style="padding:2px 8px;font-size:10px;">' + val + '</td></tr>';
                        }
                    });
                    fmPanel = `<details class="frontmatter-panel" open>
                        <summary style="cursor:pointer;font-size:10px;color:#808080;padding:6px 10px;background:var(--bg-secondary);border:1px solid var(--border-color);border-radius:4px 4px 0 0;user-select:none;">
                            <span style="font-weight:600;">Metadata</span>
                        </summary>
                        <div style="background:var(--bg-secondary);border:1px solid var(--border-color);border-top:none;border-radius:0 0 4px 4px;padding:4px 0;">
                            <table style="width:100%;border-collapse:collapse;">${rows}</table>
                        </div>
                    </details>`;
                }

                // Wrap in markdown-body class
                html = fmPanel + '<div class="markdown-body">' + html + '</div>';

                DOM.rendered.innerHTML = html;

                // Resolve relative URLs (images, links) to absolute file:// paths
                resolveLocalURLs();

                // Convert mermaid code blocks
                const mermaidBlocks = DOM.rendered.querySelectorAll('pre code.language-mermaid');
                mermaidBlocks.forEach((code, idx) => {
                    const pre = code.parentElement;
                    const mermaidSource = code.textContent;

                    // Check if this should be interactive D3 canvas (%%INTERACTIVE marker)
                    // or standard Mermaid SVG rendering
                    if (mermaidSource.includes('%%INTERACTIVE')) {
                        // Interactive D3 canvas
                        const container = document.createElement('div');
                        container.className = 'mermaid-canvas';
                        container.setAttribute('data-source', mermaidSource);
                        container.id = 'mermaid-canvas-' + idx;
                        const viewportH = window.innerHeight || 800;
                        const canvasH = Math.max(viewportH - 120, 500);
                        container.style.cssText = 'width:100%;height:' + canvasH + 'px;border:1px solid var(--border-color);border-radius:6px;margin:12px 0;position:relative;overflow:hidden;';
                        pre.replaceWith(container);
                        container.innerHTML = '<div style="display:flex;align-items:center;justify-content:center;height:100%;gap:8px;"><div style="width:20px;height:20px;border:2px solid #569cd6;border-top-color:transparent;border-radius:50%;animation:spin 1s linear infinite;"></div><span style="color:#808080;font-size:11px;">Building interactive graph...</span></div>';
                        setTimeout(() => initMermaidCanvas(container, mermaidSource), 200);
                    } else {
                        // Standard Mermaid SVG rendering
                        const div = document.createElement('div');
                        div.className = 'mermaid';
                        div.textContent = mermaidSource;
                        div.setAttribute('data-source', mermaidSource);
                        pre.replaceWith(div);
                    }
                });

                // Highlight code blocks (Prism.js) — skip mermaid (already converted)
                if (typeof Prism !== 'undefined') {
                    setTimeout(() => {
                        DOM.rendered.querySelectorAll('pre code').forEach(el => {
                            Prism.highlightElement(el);
                        });
                    }, 0);
                }

                // Render mermaid diagrams
                if (typeof mermaid !== 'undefined') {
                    setTimeout(() => {
                        try {
                            const nodes = DOM.rendered.querySelectorAll('.mermaid');
                            if (nodes.length > 0) {
                                const done = mermaid.run({ nodes: nodes });
                                // Expand buttons go in after the SVGs exist —
                                // mermaid.run replaces each div's content. One
                                // broken diagram rejects the promise while the
                                // rest still render, so decorate on both paths.
                                const decorate = () => { try { decorateMermaidDiagrams(); } catch(e3) {} };
                                if (done && typeof done.then === 'function') {
                                    done.then(decorate, decorate);
                                } else {
                                    setTimeout(decorate, 300);
                                }
                            }
                        } catch(e) {
                            // Fallback for older mermaid API
                            try { mermaid.contentLoaded(); } catch(e2) {}
                            setTimeout(() => { try { decorateMermaidDiagrams(); } catch(e3) {} }, 300);
                        }
                    }, 0);
                }

                // Formulas are rendered by markdown-it itself (markview-mdext.js), before
                // emphasis can break TeX like `\Delta_\mu`; no post-pass over the HTML.

                // Extract headings
                extractHeadings();

                // Extract semantic blocks and send delta to Swift
                try {
                    const newBlocks = extractBlocks(markdown);
                    const delta = diffBlocks(previousBlocks, newBlocks);
                    previousBlocks = newBlocks; // reassign, don't spread (large arrays overflow stack)

                    if (delta.added.length || delta.removed.length || delta.changed.length) {
                        // Send only block metadata, not full content (avoid huge payloads)
                        const slim = (blocks) => blocks.map(b => ({
                            id: b.id, documentId: b.documentId, type: b.type,
                            level: b.level, content: b.content, plainText: b.plainText,
                            contentHash: b.contentHash, headingPath: b.headingPath,
                            parentBlockId: b.parentBlockId, lineStart: b.lineStart,
                            lineEnd: b.lineEnd, position: b.position,
                            language: b.language, anchor: b.anchor
                        }));
                        sendToSwift('blocksChanged', {
                            added: slim(delta.added),
                            removed: delta.removed,
                            changed: slim(delta.changed),
                            unchanged: delta.unchanged
                        });
                    }
                } catch(e) {
                    console.warn('Block extraction error:', e);
                }

                // Update character count
                updateStats();

                // Send to Swift bridge
                sendToSwift('contentChanged', {
                    markdown: state.markdown,
                    html: DOM.rendered.innerHTML
                });
            } catch (error) {
                console.error('Render error:', error);
            } finally {
                state.isRendering = false;
            }
        }

        // ============================================================================
        // HEADING EXTRACTION & TOC
        // ============================================================================

        let headingIdCounter = 0;

        function extractHeadings() {
            const headings = [];
            const headingMap = new Map();

            DOM.rendered.querySelectorAll('h1, h2, h3, h4, h5, h6').forEach(heading => {
                const level = parseInt(heading.tagName[1]);
                let id = heading.id;

                if (!id) {
                    // Generate stable ID from text (Unicode-aware — supports Cyrillic, CJK, etc.)
                    let text = heading.textContent.trim();
                    id = text
                        .toLowerCase()
                        .replace(/\s+/g, '-')
                        .replace(/[^\p{L}\p{N}-]/gu, '')
                        .replace(/--+/g, '-')
                        .replace(/^-+|-+$/g, '') || `heading-${headingIdCounter++}`;

                    // Ensure uniqueness
                    if (headingMap.has(id)) {
                        let count = headingMap.get(id) + 1;
                        headingMap.set(id, count);
                        id = `${id}-${count}`;
                    } else {
                        headingMap.set(id, 1);
                    }

                    heading.id = id;
                }

                headings.push({
                    id: id,
                    level: level,
                    text: heading.textContent.trim()
                });
            });

            state.headings = headings;

            // Update TOC in status
            updateTOCStatus();

            // Send to Swift
            sendToSwift('headingsUpdated', headings);
        }

        function updateTOCStatus() {
            const items = state.headings.slice(0, 5);
            if (items.length === 0) {
                DOM.tocStatus.innerHTML = '';
            } else {
                const tocHTML = 'Headings: ' + items.map(h => `<strong>${h.text}</strong>`).join(' → ');
                DOM.tocStatus.innerHTML = tocHTML;
            }
        }

        // ============================================================================
        // BLOCK EXTRACTION (DDE Stage 1)
        // ============================================================================

        var previousBlocks = [];

        function fnv1a(str) {
            let hash = 0x811c9dc5;
            for (let i = 0; i < str.length; i++) {
                hash ^= str.charCodeAt(i);
                hash = (hash * 0x01000193) >>> 0;
            }
            return hash.toString(16);
        }

        function extractBlocks(markdownText) {
            const lines = markdownText.split('\n');
            const blocks = [];
            const headingStack = []; // current heading path
            let currentBlock = null;
            let position = 0;

            function flushBlock() {
                if (currentBlock && currentBlock.content.trim()) {
                    currentBlock.contentHash = fnv1a(currentBlock.content);
                    const pathKey = currentBlock.headingPath.join('/') + ':' + currentBlock.position;
                    currentBlock.id = fnv1a(pathKey);
                    currentBlock.plainText = currentBlock.content
                        .replace(/[#*_`~\[\]()>!|]/g, '')
                        .replace(/\s+/g, ' ')
                        .trim();
                    blocks.push(currentBlock);
                }
            }

            function newBlock(type, lineStart, level, language) {
                return {
                    id: '',
                    documentId: '',
                    type: type,
                    level: level || null,
                    content: '',
                    plainText: '',
                    contentHash: '',
                    headingPath: [...headingStack],
                    parentBlockId: null,
                    lineStart: lineStart,
                    lineEnd: lineStart,
                    position: position++,
                    language: language || null,
                    anchor: null
                };
            }

            let inCodeBlock = false;
            let codeBlockLang = null;

            for (let i = 0; i < lines.length; i++) {
                const line = lines[i];

                // Code block fences
                if (line.trimStart().startsWith('```')) {
                    if (!inCodeBlock) {
                        flushBlock();
                        codeBlockLang = line.trim().slice(3).trim() || null;
                        currentBlock = newBlock('codeBlock', i + 1, null, codeBlockLang);
                        currentBlock.content = line + '\n';
                        inCodeBlock = true;
                        continue;
                    } else {
                        currentBlock.content += line;
                        currentBlock.lineEnd = i + 1;
                        inCodeBlock = false;
                        flushBlock();
                        currentBlock = null;
                        continue;
                    }
                }

                if (inCodeBlock) {
                    currentBlock.content += line + '\n';
                    currentBlock.lineEnd = i + 1;
                    continue;
                }

                // Headings
                const headingMatch = line.match(/^(#{1,6})\s+(.+)/);
                if (headingMatch) {
                    flushBlock();
                    const level = headingMatch[1].length;
                    const text = headingMatch[2].trim();

                    // Update heading stack
                    while (headingStack.length >= level) headingStack.pop();
                    headingStack.push(text);

                    currentBlock = newBlock('section', i + 1, level);
                    currentBlock.content = line;
                    currentBlock.lineEnd = i + 1;
                    currentBlock.anchor = text.toLowerCase()
                        .replace(/\s+/g, '-')
                        .replace(/[^\p{L}\p{N}-]/gu, '')
                        .replace(/--+/g, '-')
                        .replace(/^-+|-+$/g, '');
                    flushBlock();
                    currentBlock = null;
                    continue;
                }

                // Empty line — flush current block
                if (line.trim() === '') {
                    if (currentBlock) {
                        currentBlock.content += '\n';
                        currentBlock.lineEnd = i + 1;
                    }
                    flushBlock();
                    currentBlock = null;
                    continue;
                }

                // Table rows
                if (line.trim().startsWith('|') && line.trim().endsWith('|')) {
                    if (!currentBlock || currentBlock.type !== 'table') {
                        flushBlock();
                        currentBlock = newBlock('table', i + 1);
                    }
                    currentBlock.content += line + '\n';
                    currentBlock.lineEnd = i + 1;
                    continue;
                }

                // Blockquotes
                if (line.trimStart().startsWith('>')) {
                    if (!currentBlock || currentBlock.type !== 'quote') {
                        flushBlock();
                        currentBlock = newBlock('quote', i + 1);
                    }
                    currentBlock.content += line + '\n';
                    currentBlock.lineEnd = i + 1;
                    continue;
                }

                // List items
                if (/^\s*[-*+]\s/.test(line) || /^\s*\d+\.\s/.test(line)) {
                    if (!currentBlock || (currentBlock.type !== 'list' && currentBlock.type !== 'listItem')) {
                        flushBlock();
                        currentBlock = newBlock('list', i + 1);
                    }
                    currentBlock.content += line + '\n';
                    currentBlock.lineEnd = i + 1;
                    continue;
                }

                // Paragraph (default)
                if (!currentBlock) {
                    currentBlock = newBlock('paragraph', i + 1);
                }
                currentBlock.content += line + '\n';
                currentBlock.lineEnd = i + 1;
            }

            // Flush last block
            flushBlock();

            return blocks;
        }

        function diffBlocks(oldBlocks, newBlocks) {
            const oldMap = new Map(oldBlocks.map(b => [b.id, b]));
            const newMap = new Map(newBlocks.map(b => [b.id, b]));

            const added = [];
            const removed = [];
            const changed = [];
            const unchanged = [];

            // Find added and changed
            for (const block of newBlocks) {
                const old = oldMap.get(block.id);
                if (!old) {
                    added.push(block);
                } else if (old.contentHash !== block.contentHash) {
                    changed.push(block);
                } else {
                    unchanged.push(block.id);
                }
            }

            // Find removed
            for (const block of oldBlocks) {
                if (!newMap.has(block.id)) {
                    removed.push(block.id);
                }
            }

            return { added, removed, changed, unchanged };
        }

        // IntersectionObserver for active heading
        function setupHeadingObserver() {
            const options = {
                root: DOM.rendered,
                rootMargin: '-80px 0px -66% 0px',
                threshold: 0
            };

            const observer = new IntersectionObserver((entries) => {
                let activeId = null;
                for (let entry of entries) {
                    if (entry.isIntersecting && entry.target.id) {
                        activeId = entry.target.id;
                        break;
                    }
                }

                if (activeId !== state.activeHeadingId) {
                    state.activeHeadingId = activeId;
                    sendToSwift('scrollPosition', { activeHeadingId: activeId });
                }
            }, options);

            // Observe headings
            setTimeout(() => {
                DOM.rendered.querySelectorAll('h1, h2, h3, h4, h5, h6').forEach(heading => {
                    observer.observe(heading);
                });
            }, 100);
        }

        // ============================================================================
