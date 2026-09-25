        // ============================================================================
        // Code viewer — read-only CodeMirror 6 (vendor/js/codemirror.bundle.js, loaded
        // on first use). Swift calls setCodeContent(text, language, fileName) for any
        // source file; every other content entry point leaves the code view.
        // ============================================================================
        (function() {
            const container = document.getElementById('code-container');
            // Code on the left, AI margin notes on the right.
            const main = document.createElement('div'); main.className = 'code-main';
            const explainButton = document.createElement('button');
            explainButton.className = 'code-explain-btn'; explainButton.textContent = '✦ Explain';
            explainButton.title = 'Explain this file section by section (AI)';
            main.appendChild(explainButton);
            // A markdown document opened with its notes: the way back to the document.
            const documentButton = document.createElement('button');
            documentButton.className = 'code-document-btn'; documentButton.textContent = '← Document';
            documentButton.title = 'Back to the formatted document (editable)';
            documentButton.hidden = true;
            main.appendChild(documentButton);
            // In the markdown document itself: open the same notes as for code.
            const docExplainButton = document.createElement('button');
            docExplainButton.className = 'code-explain-btn doc-explain-btn'; docExplainButton.textContent = '✦ Explain';
            docExplainButton.title = 'Explain this document section by section, with importance, freshness and filters';
            DOM.previewPane.appendChild(docExplainButton);
            let explainOnOpen = false;   // the document's Explain was pressed: start it once the notes view is up
            // Zoom: shrink the code (down to a minimap) while the notes compact but stay readable.
            const zoomBar = document.createElement('div'); zoomBar.className = 'code-zoom';
            zoomBar.innerHTML = '<button data-z="out" title="Zoom out">−</button><span class="code-zoom-level">100%</span>'
                + '<button data-z="in" title="Zoom in">+</button><button data-z="fit" title="Fit the whole file">Fit file</button>'
                + '<button data-z="reset" title="Actual size">1:1</button>';
            main.appendChild(zoomBar);
            // Lens levels drawn on the code itself: tinted or dimmed line bands, and a
            // whole-file heat strip along the right edge (click to jump).
            const bands = document.createElement('div'); bands.className = 'code-bands';
            bands.innerHTML = '<div class="code-bands-track"></div>';
            const bandsTrack = bands.firstChild;
            const heat = document.createElement('div'); heat.className = 'code-heat';
            heat.innerHTML = '<div class="code-heat-view"></div>';
            const heatView = heat.firstChild;
            main.appendChild(bands);
            main.appendChild(heat);
            // Text size at 100%: the editor's font slider (markview-edit.js), 13 px by default.
            let baseSize = 13;
            try { baseSize = parseFloat(localStorage.getItem('markview-font-size')) || 13; } catch (e) {}
            let codeSize = baseSize;
            container.style.setProperty('--mv-code-size', codeSize + 'px');
            const notes = document.createElement('aside'); notes.className = 'code-notes'; notes.hidden = true;
            notes.innerHTML = '<div class="code-notes-head"><select class="code-lens" title="What the notes show"></select>'
                + '<span class="code-notes-status"></span>'
                + '<button class="code-notes-info" title="">ⓘ</button>'
                + '<button class="code-notes-redo" title="Explain again">↻</button>'
                + '<button class="code-notes-close" title="Hide notes">✕</button></div>'
                + '<form class="temp-filter code-temp-filter" title="A one-off AI filter: applied now, not saved">'
                + '<input placeholder="⚡ Quick AI filter, e.g. payment flow"><button type="button" hidden title="Clear">✕</button></form>'
                + '<div class="code-notes-legend"></div>'
                + '<form class="code-new-filter" hidden><input placeholder="Topic or question, e.g. payment flow">'
                + '<button type="submit">Add</button></form>'
                + '<div class="code-notes-viewport"><div class="code-notes-track"></div></div>';
            container.appendChild(main);
            container.appendChild(notes);
            // Drag the notes' left edge to resize them; double-click restores the default width.
            const resizer = document.createElement('div'); resizer.className = 'code-notes-resizer';
            notes.appendChild(resizer);
            window.MVPanels.resizable({ handle: resizer, panel: notes, host: container, key: 'markview-code-notes-width',
                                        width: 320, onResize: function() { queueLayout(); } });
            const lens = notes.querySelector('.code-lens');
            const track = notes.querySelector('.code-notes-track');
            const notesStatus = notes.querySelector('.code-notes-status');
            const info = notes.querySelector('.code-notes-info');
            const viewport = notes.querySelector('.code-notes-viewport');
            const legend = notes.querySelector('.code-notes-legend');
            let notesState = null;      // last payload from Swift
            let pendingLens = null;     // a filter just created here becomes the lens
            let notesHidden = false;
            let marked = [];            // sections with a lens level: {start, end, level, title}
            let layoutQueued = false;
            let viewer = null;
            let loading = null;
            let docPending = false;   // a setCodeContent is waiting for the bundle

            /**
             * Formatted markdown with the same interface as the CodeMirror viewer, so the
             * margin notes work unchanged. Blocks carry their source line (`data-line`,
             * from markdown-it's token map), which is how a section's lines find their
             * place in the formatted text.
             */
            function createMarkdownViewer(host) {
                const scroller = document.createElement('div'); scroller.className = 'md-viewer';
                const body = document.createElement('div'); body.className = 'markdown-body md-viewer-body';
                scroller.appendChild(body);
                host.appendChild(scroller);
                const listeners = [];
                let blocks = [];   // [{line, el}] by source line
                function notify() { listeners.forEach(function(fn) { fn(); }); }
                scroller.addEventListener('scroll', notify, { passive: true });
                if (window.ResizeObserver) new ResizeObserver(notify).observe(scroller);
                function measure() {
                    blocks = Array.from(body.querySelectorAll('[data-line]'))
                        .map(function(el) { return { line: +el.getAttribute('data-line'), el: el }; })
                        .sort(function(a, b) { return a.line - b.line; });
                }
                function top(el) { return el.getBoundingClientRect().top - scroller.getBoundingClientRect().top + scroller.scrollTop; }
                function lineTop(n) {
                    let best = null;
                    for (let i = 0; i < blocks.length && blocks[i].line <= n; i++) best = blocks[i];
                    return best ? top(best.el) : 0;
                }
                function lineBottom(n) {
                    const next = blocks.find(function(b) { return b.line > n; });
                    return next ? top(next.el) : scroller.scrollHeight;
                }
                return {
                    kind: 'markdown',
                    element: scroller,
                    scrollerEl: function() { return scroller; },
                    setDoc: function(text) {
                        const fm = text.match(/^---\r?\n[\s\S]*?\r?\n---\r?\n/);
                        const offset = fm ? fm[0].split('\n').length - 1 : 0;
                        const source = fm ? text.slice(fm[0].length) : text;
                        let html;
                        try {
                            const tokens = md.parse(source, {});
                            tokens.forEach(function(t) {
                                if (t.map && t.block && t.nesting >= 0) t.attrSet('data-line', String(t.map[0] + 1 + offset));
                            });
                            html = md.renderer.render(tokens, md.options, {});
                        } catch (e) {
                            html = '<pre>' + source.replace(/&/g, '&amp;').replace(/</g, '&lt;') + '</pre>';
                        }
                        body.innerHTML = html;
                        scroller.scrollTop = 0;
                        measure();
                        notify();
                    },
                    setTheme: function() {},
                    onLayout: function(fn) { listeners.push(fn); },
                    refresh: function() { measure(); notify(); },
                    /** Scale the whole text, images included, so "Fit file" really fits. */
                    setScale: function(scale) { body.style.zoom = String(scale); measure(); notify(); },
                    fitScale: function(scale) { return scale * Math.max(0.01, (scroller.clientHeight - 20) / Math.max(1, scroller.scrollHeight)); },
                    viewportHeight: function() { return scroller.clientHeight; },
                    lineCount: function() { return blocks.length ? blocks[blocks.length - 1].line : 1; },
                    geometry: function() {
                        return { height: scroller.scrollHeight, scrollTop: scroller.scrollTop, lineTop: lineTop, lineBottom: lineBottom };
                    },
                    gotoLine: function(start, end) {
                        scroller.scrollTop = Math.max(0, lineTop(start) - 24);
                        blocks.forEach(function(b) {
                            if (b.line >= start && b.line <= (end || start)) {
                                b.el.classList.add('md-flash');
                                setTimeout(function() { b.el.classList.remove('md-flash'); }, 1600);
                            }
                        });
                    },
                    openSearch: function() {},
                };
            }
            let codeViewer = null, mdViewer = null;

            /** The element that scrolls in the current viewer. */
            function scrollerEl() {
                return viewer && viewer.scrollerEl ? viewer.scrollerEl() : main.querySelector('.cm-scroller');
            }

            function loadBundle() {
                if (window.MVCode) return Promise.resolve();
                if (loading) return loading;
                loading = new Promise(function(resolve, reject) {
                    const script = document.createElement('script');
                    script.src = 'vendor/js/codemirror.bundle.js';
                    script.onload = function() { resolve(); };
                    script.onerror = function() { loading = null; reject(new Error('codemirror.bundle.js failed to load')); };
                    document.head.appendChild(script);
                });
                return loading;
            }

            function isDark() {
                return document.documentElement.getAttribute('data-theme') === 'dark';
            }

            function enterCodeView(language) {
                if (typeof leaveInsightView === 'function') leaveInsightView();
                if (typeof window.leaveCanvasView === 'function') window.leaveCanvasView();
                state.mode = 'code';
                state.fileType = 'code';
                DOM.editorPane.style.display = 'none';
                DOM.previewPane.style.display = 'none';
                document.getElementById('wysiwyg-toolbar').style.display = 'none';
                document.body.classList.add('code-mode');
                container.classList.add('visible');
                DOM.statusMode.textContent = language ? language.toUpperCase() : 'TEXT';
            }

            window.leaveCodeView = function() {
                if (!container.classList.contains('visible')) return;
                container.classList.remove('visible');
                document.body.classList.remove('code-mode');
                document.getElementById('wysiwyg-toolbar').style.display = '';
            };

            /** Show `text` read-only with syntax highlighting for `language`. */
            window.setCodeContent = function(text, language, fileName) {
                currentFile = fileName || null;
                enterCodeView(language);
                documentButton.hidden = language !== 'markdown';
                state.markdown = text;
                docPending = true;
                notesState = null;
                renderNotes();
                // Markdown with notes stays formatted; everything else is code.
                if (language === 'markdown') {
                    if (!mdViewer) { mdViewer = createMarkdownViewer(main); mdViewer.onLayout(queueLayout); }
                    viewer = mdViewer;
                    mdViewer.element.hidden = false;
                    if (codeViewer && codeViewer.element) codeViewer.element.hidden = true;
                    mdViewer.setScale(codeSize / baseSize);
                    mdViewer.setDoc(text);
                    docPending = false;
                    if (window.pendingCodeLine) {
                        const target = window.pendingCodeLine;
                        window.pendingCodeLine = null;
                        viewer.gotoLine(target.line, target.endLine);
                    }
                    return;
                }
                if (mdViewer) mdViewer.element.hidden = true;
                loadBundle().then(function() {
                    if (!codeViewer) {
                        codeViewer = window.MVCode.create(main, { doc: text, language: language, dark: isDark() });
                        codeViewer.onLayout(queueLayout);
                        codeViewer.element = main.querySelector('.cm-editor');
                    } else {
                        codeViewer.setDoc(text, language);
                        codeViewer.setTheme(isDark());
                    }
                    if (codeViewer.element) codeViewer.element.hidden = false;
                    viewer = codeViewer;
                    docPending = false;
                    if (window.pendingCodeLine) {
                        const target = window.pendingCodeLine;
                        window.pendingCodeLine = null;
                        viewer.gotoLine(target.line, target.endLine);
                    }
                }).catch(function(error) {
                    container.textContent = 'Code viewer failed to load: ' + error.message;
                });
            };

            /** Select and centre a 1-based line range (queued until the viewer exists). */
            window.codeGotoLine = function(line, endLine) {
                if (viewer && state.mode === 'code' && !docPending) viewer.gotoLine(line, endLine);
                else window.pendingCodeLine = { line: line, endLine: endLine };
            };

            // ------------------------------------------------------------ margin notes

            function postCode(action, fields) {
                try { window.webkit.messageHandlers.bridge.postMessage({ type: 'code', payload: Object.assign({ action: action }, fields || {}) }); }
                catch (e) { console.log('[code] post failed', e); }
            }

            const levelColors = {
                recent: '#2b54d9', months: '#2fa37a', years: '#d9982b', old: '#8a9199',
                critical: '#d9534f', high: '#d9982b', normal: '#5a8bd6', low: '#8a9199',
                // Relevance runs cold → hot in distinct hues, so each level reads at a glance.
                strong: '#e0457b', moderate: '#e2a93b', weak: '#3fb8d0', none: 'transparent',
                // Pull request lens: what the change did to each part.
                added: '#2ea043', changed: '#d29922', removed: '#e5534b', moved: '#58a6ff',
            };

            // How a level marks the code: a tint (with an edge bar) or 'dim' to push it back.
            const levelMarks = {
                critical: 'rgba(217, 83, 79, .17)', high: 'rgba(217, 152, 43, .13)', low: 'dim',
                strong: 'rgba(224, 69, 123, .18)', moderate: 'rgba(226, 169, 59, .13)', weak: 'rgba(63, 184, 208, .08)', none: 'dim',
                recent: 'rgba(43, 84, 217, .13)', months: 'rgba(47, 163, 122, .09)',
                added: 'rgba(46, 160, 67, .18)', removed: 'rgba(229, 83, 75, .30)',
            };

            function renderBands() {
                bandsTrack.textContent = '';
                heat.querySelectorAll('.code-heat-seg').forEach(function(el) { el.remove(); });
                const show = !notes.hidden && marked.some(function(m) { return levelMarks[m.level]; });
                bands.hidden = heat.hidden = !show;
                main.classList.toggle('with-heat', show);
                if (!show) return;
                const editor = viewer && viewer.element ? viewer.element : main.querySelector('.cm-editor');
                if (editor) container.style.setProperty('--mv-code-bg', getComputedStyle(editor).backgroundColor);
                marked.forEach(function(m) {
                    const mark = levelMarks[m.level];
                    if (!mark) return;
                    const band = document.createElement('div');
                    band.className = 'code-band' + (mark === 'dim' ? ' dim' : '');
                    band.dataset.start = m.start; band.dataset.end = m.end;
                    if (mark !== 'dim') { band.style.background = mark; band.style.borderLeftColor = m.color || levelColors[m.level]; }
                    bandsTrack.appendChild(band);
                    const seg = document.createElement('div'); seg.className = 'code-heat-seg';
                    seg.dataset.start = m.start; seg.dataset.end = m.end;
                    seg.style.background = mark === 'dim' ? 'var(--border-color)' : m.color || levelColors[m.level];
                    seg.title = m.title + ' · ' + m.level + ' (L' + m.start + '–' + m.end + ')';
                    heat.appendChild(seg);
                });
            }

            function layoutBands(geo, scroller) {
                if (bands.hidden || !scroller) return;
                const top = scroller.getBoundingClientRect().top - main.getBoundingClientRect().top;
                bands.style.top = heat.style.top = top + 'px';
                bands.style.height = heat.style.height = scroller.clientHeight + 'px';
                bandsTrack.style.transform = 'translateY(' + (-geo.scrollTop) + 'px)';
                bandsTrack.querySelectorAll('.code-band').forEach(function(band) {
                    const y = geo.lineTop(+band.dataset.start);
                    band.style.top = y + 'px';
                    band.style.height = Math.max(1, geo.lineBottom(+band.dataset.end) - y) + 'px';
                });
                // The strip maps the whole file onto the visible height.
                const h = scroller.clientHeight, total = Math.max(1, geo.height);
                heat.querySelectorAll('.code-heat-seg').forEach(function(seg) {
                    const y = geo.lineTop(+seg.dataset.start) / total * h;
                    seg.style.top = y + 'px';
                    seg.style.height = Math.max(2, geo.lineBottom(+seg.dataset.end) / total * h - y) + 'px';
                });
                heatView.style.top = geo.scrollTop / geo.height * h + 'px';
                heatView.style.height = Math.max(4, Math.min(1, h / geo.height) * h) + 'px';
            }

            heat.addEventListener('click', function(e) {
                const scroller = scrollerEl();
                if (!viewer || !scroller) return;
                const seg = e.target.classList.contains('code-heat-seg') ? e.target : null;
                if (seg) { viewer.gotoLine(+seg.dataset.start, +seg.dataset.end); return; }
                const ratio = (e.clientY - heat.getBoundingClientRect().top) / heat.clientHeight;
                scroller.scrollTop = ratio * viewer.geometry().height - scroller.clientHeight / 2;
            });

            function currentRatings() {
                const exp = notesState && notesState.explanation;
                if (!exp || lens.value === 'explain' || lens.value === 'freshness') return null;
                return (exp.ratings || {})[lens.value] || null;
            }

            /** Importance comes with the explanation itself; other filters need their own AI rating. */
            function needsRating() {
                return lens.value !== 'explain' && lens.value !== 'freshness' && lens.value !== 'importance';
            }

            function ago(unix) {
                const days = Math.max(0, Math.round((Date.now() / 1000 - unix) / 86400));
                if (days < 1) return 'today';
                if (days < 45) return days + (days === 1 ? ' day ago' : ' days ago');
                if (days < 540) return Math.round(days / 30) + ' months ago';
                return (days / 365).toFixed(1).replace('.0', '') + ' years ago';
            }
            // Freshness runs smoothly from "just changed" to "untouched for years".
            const FRESHNESS = [[0, 'today', '#2b54d9'], [30, '1 mo', '#3f8fd0'], [180, '6 mo', '#2fa37a'], [730, '2 y', '#d9982b'], [1460, '4 y+', '#8a9199']];
            function mixHex(a, b, t) {
                const x = [1, 3, 5].map(function(i) { return parseInt(a.slice(i, i + 2), 16); });
                const y = [1, 3, 5].map(function(i) { return parseInt(b.slice(i, i + 2), 16); });
                return '#' + x.map(function(v, i) { return Math.round(v + (y[i] - v) * Math.max(0, Math.min(1, t))).toString(16).padStart(2, '0'); }).join('');
            }
            function freshnessColor(unix) {
                const days = Math.max(0, (Date.now() / 1000 - unix) / 86400);
                for (let i = 0; i < FRESHNESS.length - 1; i++) {
                    if (days <= FRESHNESS[i + 1][0]) return mixHex(FRESHNESS[i][2], FRESHNESS[i + 1][2], (days - FRESHNESS[i][0]) / (FRESHNESS[i + 1][0] - FRESHNESS[i][0]));
                }
                return FRESHNESS[FRESHNESS.length - 1][2];
            }

            /** What the colours mean for the current lens: a labelled gradient. */
            function renderLegend() {
                legend.textContent = '';
                const filter = ((notesState && notesState.filters) || []).find(function(f) { return f.id === lens.value; });
                const stops = lens.value === 'freshness' ? FRESHNESS
                    : lens.value === 'explain' || lens.value === 'importance'
                    ? ['low', 'normal', 'high', 'critical'].map(function(l) { return [0, l, levelColors[l]]; })
                    : filter ? filter.levels.slice().reverse().map(function(l) { return [0, l, levelColors[l] === 'transparent' ? '#8a9199' : levelColors[l]]; })
                    : null;
                legend.hidden = !stops || notes.hidden;
                if (!stops) return;
                const title = document.createElement('b');
                title.textContent = lens.value === 'freshness' ? 'Last change' : filter && filter.id !== 'importance' ? 'Relevance' : 'Importance';
                legend.appendChild(title);
                stops.forEach(function(stop, i) {
                    const label = document.createElement('span'); label.textContent = stop[1]; legend.appendChild(label);
                    if (!stops[i + 1]) return;
                    const seg = document.createElement('i');
                    seg.style.background = 'linear-gradient(to right, ' + stop[2] + ', ' + stops[i + 1][2] + ')';
                    legend.appendChild(seg);
                });
            }

            function freshnessLevel(unix) {
                const days = (Date.now() / 1000 - unix) / 86400;
                return days < 31 ? 'recent' : days < 183 ? 'months' : days < 730 ? 'years' : 'old';
            }

            function queueLayout() {
                if (layoutQueued) return;
                layoutQueued = true;
                requestAnimationFrame(function() { layoutQueued = false; layoutNotes(); });
            }

            /** Place each note at its section's first line, pushed down past the previous note. */
            function layoutNotes() {
                if (!viewer || notes.hidden) return;
                const geo = viewer.geometry();
                // Align with the code: the notes viewport starts lower than the code's scroller.
                const scroller = scrollerEl();
                layoutBands(geo, scroller);
                const offset = scroller ? scroller.getBoundingClientRect().top - viewport.getBoundingClientRect().top : 0;
                track.style.height = geo.height + 'px';
                track.style.transform = 'translateY(' + (offset - geo.scrollTop) + 'px)';
                const cards = Array.from(track.querySelectorAll('.code-note'));
                const gap = codeSize < 8 ? 2 : 6;
                // First visible track position (cards above it stick to the top edge).
                const visibleTop = geo.scrollTop - offset;
                // Bottom of the visible part of the notes, in track coordinates.
                const limit = visibleTop + viewport.clientHeight - 4;
                // Pass 1: each note as large as the room before the next section allows.
                // Pass 2 (only if the stack runs past the file): shrink everything to strips.
                for (let pass = 0; pass < 2; pass++) {
                    let bottom = visibleTop - gap;
                    cards.forEach(function(card, i) {
                        const top = Math.max(geo.lineTop(+card.dataset.start), bottom + gap);
                        const next = cards[i + 1] ? geo.lineTop(+cards[i + 1].dataset.start) : Infinity;
                        const room = next - top - gap;
                        card.classList.remove('compact', 'mini');
                        if (pass === 1) {
                            card.classList.add('mini');
                        } else if (card.offsetHeight > room) {
                            card.classList.add('compact');
                            if (card.offsetHeight > room) { card.classList.remove('compact'); card.classList.add('mini'); }
                        }
                        card.style.top = top + 'px';
                        bottom = top + card.offsetHeight;
                    });
                    // Shrink to strips only when the whole file is on screen and the notes are not.
                    const wholeFileVisible = geo.height <= viewer.viewportHeight() * 1.05 + 16;
                    if (!wholeFileVisible || bottom <= limit) break;
                }
                // Whole file on screen: lift the tail so the last notes stay visible too (still no overlap).
                if (geo.height <= viewer.viewportHeight() * 1.05 + 16) {
                    let ceiling = limit;
                    for (let i = cards.length - 1; i >= 0; i--) {
                        const h = cards[i].offsetHeight;
                        const top = Math.min(parseFloat(cards[i].style.top), ceiling - h);
                        cards[i].style.top = Math.max(visibleTop, top) + 'px';
                        ceiling = top - gap;
                    }
                }
                let bottom = 0;
                cards.forEach(function(card) {
                    const start = +card.dataset.start, end = +card.dataset.end;
                    bottom = Math.max(bottom, parseFloat(card.style.top) + card.offsetHeight);
                    const bar = card.previousElementSibling;
                    if (bar && bar.classList.contains('code-note-span')) {
                        bar.style.top = geo.lineTop(start) + 'px';
                        bar.style.height = Math.max(2, geo.lineBottom(end) - geo.lineTop(start)) + 'px';
                    }
                });
                track.style.height = Math.max(geo.height, bottom + 8) + 'px';
            }

            /** Font slider moved: keep the current zoom factor on the new base size. */
            window.setCodeBaseSize = function(size) {
                const factor = codeSize / baseSize;
                baseSize = size;
                setZoom(size * factor);
            };

            function setZoom(size) {
                codeSize = Math.min(28, Math.max(0.25, size));
                container.style.setProperty('--mv-code-size', codeSize + 'px');
                container.classList.toggle('code-zoomed-out', codeSize < 8);
                zoomBar.querySelector('.code-zoom-level').textContent = Math.round(codeSize / baseSize * 100) + '%';
                if (viewer && viewer.setScale) viewer.setScale(codeSize / baseSize);
                else if (viewer) viewer.refresh();
                queueLayout();
            }

            /** Zoom in on one section: readable size (larger if it is short), scrolled to it, selected. */
            function zoomToSection(start, end) {
                if (!viewer) return;
                if (viewer.kind === 'markdown') {
                    setZoom(baseSize);
                    requestAnimationFrame(function() { viewer.gotoLine(start, end); });
                    return;
                }
                const lines = end - start + 1;
                const fits = (viewer.viewportHeight() - 60) / (lines * 1.55);
                setZoom(Math.max(baseSize, Math.min(fits, baseSize * 1.6)));
                // Wait for the new line heights before scrolling to the section.
                requestAnimationFrame(function() {
                    requestAnimationFrame(function() {
                        viewer.gotoLine(start, end);
                        const geo = viewer.geometry();
                        const scroller = scrollerEl();
                        if (scroller) scroller.scrollTop = Math.max(0, geo.lineTop(start) - 24);
                    });
                });
            }

            function fitWholeFile() {
                if (!viewer) return;
                if (viewer.fitScale) { setZoom(baseSize * viewer.fitScale(codeSize / baseSize)); return; }
                // Line height is 1.55 × font size; leave room for the editor's padding.
                setZoom((viewer.viewportHeight() - 20) / (viewer.lineCount() * 1.55));
            }

            zoomBar.addEventListener('click', function(e) {
                const z = e.target.getAttribute && e.target.getAttribute('data-z');
                if (z === 'in') setZoom(codeSize * 1.25);
                else if (z === 'out') setZoom(codeSize / 1.25);
                else if (z === 'fit') fitWholeFile();
                else if (z === 'reset') setZoom(baseSize);
            });
            // Trackpad pinch arrives as a ctrl+wheel event.
            main.addEventListener('wheel', function(e) {
                if (!e.ctrlKey) return;
                e.preventDefault();
                setZoom(codeSize * Math.exp(-e.deltaY * 0.01));
            }, { passive: false });

            function renderLensOptions() {
                const keep = lens.value || 'explain';
                lens.textContent = '';
                const add = function(value, label) { const o = document.createElement('option'); o.value = value; o.textContent = label; lens.appendChild(o); };
                add('explain', 'Explanation');
                if (notesState && notesState.pr) add('pr', '⎇ Pull request');
                add('freshness', 'Freshness');
                ((notesState && notesState.filters) || []).forEach(function(f) { add(f.id, f.name); });
                add('__new__', '＋ New filter…');
                lens.value = Array.from(lens.options).some(function(o) { return o.value === keep; }) ? keep : 'explain';
            }

            let currentFile = null;      // name of the file in the viewer (setCodeContent)
            let prFocusApplied = null;   // the file a PR X-Ray opened on its change (applied once)
            let prRequested = null;      // the file whose change explanation was asked for

            function renderNotes() {
                const st = notesState || {};
                const exp = st.explanation;
                // Opened from the PR X-Ray: start on the change.
                if (st.pr && st.pr.focus && prFocusApplied !== currentFile) {
                    prFocusApplied = currentFile;
                    notesHidden = false;
                    renderLensOptions();
                    lens.value = 'pr';
                }
                if (lens.value === 'pr' && st.pr) { renderPRNotes(st); return; }
                notes.hidden = notesHidden || (!exp && !st.working && !st.error);
                // Hidden notes come back without a new AI call.
                explainButton.hidden = !notes.hidden;
                explainButton.textContent = exp ? '✦ Notes' : '✦ Explain';
                explainButton.title = exp ? 'Show the notes for this file' : 'Explain this file section by section (AI)';
                container.classList.toggle('with-notes', !notes.hidden);
                notesStatus.textContent = st.error ? st.error : st.working ? (st.activity || 'Working…') : st.stale ? 'File changed — explain again' : '';
                notesStatus.className = 'code-notes-status' + (st.error ? ' error' : st.working ? ' working' : '');
                renderLensOptions();
                info.title = exp ? exp.summary : '';
                info.hidden = !exp;
                track.textContent = '';
                marked = [];
                if (!exp) { renderBands(); renderLegend(); return; }
                const ratings = currentRatings();
                const fresh = lens.value === 'freshness' ? exp.freshness : null;
                if (lens.value === 'freshness' && !fresh && !st.working) postCode('freshness');
                if (needsRating() && !ratings && !st.working) postCode('rate', { filter: lens.value });
                exp.sections.forEach(function(section) {
                    const rating = ratings ? ratings['s' + section.startLine] : null;
                    const changed = fresh ? fresh['s' + section.startLine] : null;
                    const fromExplanation = lens.value === 'explain' || (lens.value === 'importance' && !rating);
                    const level = fromExplanation ? section.importance
                        : lens.value === 'freshness' ? (changed ? freshnessLevel(changed) : null)
                        : (rating ? rating.level : null);
                    if (level) marked.push({ start: section.startLine, end: section.endLine, level: level, title: section.title,
                                             color: changed ? freshnessColor(changed) : null });
                    // Freshness is a continuous scale; the other lenses have discrete levels.
                    const color = changed ? freshnessColor(changed) : levelColors[level];
                    const span = document.createElement('div'); span.className = 'code-note-span';
                    span.style.background = color || 'transparent';
                    const card = document.createElement('div'); card.className = 'code-note';
                    card.dataset.start = section.startLine; card.dataset.end = section.endLine;
                    card.style.borderLeftColor = color || 'var(--border-color)';
                    // Keyword match not yet confirmed by the AI.
                    if (rating && rating.provisional) { card.style.borderLeftStyle = 'dashed'; card.classList.add('provisional'); }
                    const head = document.createElement('div'); head.className = 'code-note-title';
                    head.textContent = section.title;
                    const meta = document.createElement('span'); meta.className = 'code-note-meta';
                    meta.textContent = 'L' + section.startLine + '–' + section.endLine
                        + (lens.value === 'freshness' ? (changed ? ' · ' + ago(changed) : '') : (level ? ' · ' + (rating && rating.provisional ? '≈ ' : '') + level : ''));
                    head.appendChild(meta);
                    const body = document.createElement('div'); body.className = 'code-note-body';
                    body.textContent = fromExplanation || lens.value === 'freshness' ? section.explanation
                        : rating ? rating.reason : (st.working ? 'Rating…' : '');
                    card.appendChild(head); card.appendChild(body);
                    card.title = section.title + ' (L' + section.startLine + '–' + section.endLine + ')\n\n' + body.textContent;
                    card.style.setProperty('--note-color', color || 'var(--border-color)');
                    card.onclick = function() { if (viewer) viewer.gotoLine(section.startLine, section.endLine); };
                    card.ondblclick = function() { zoomToSection(section.startLine, section.endLine); };
                    track.appendChild(span); track.appendChild(card);
                });
                renderBands();
                renderLegend();
                queueLayout();
            }

            /** "Pull request" lens: added lines and removal points on the code, and each change
             *  of the selected pull request with what it does and why, and its own diff lines. */
            function renderPRNotes(st) {
                const pr = st.pr;
                notes.hidden = notesHidden;
                explainButton.hidden = !notes.hidden;
                container.classList.toggle('with-notes', !notes.hidden);
                renderLensOptions();
                notesStatus.textContent = pr.explaining ? 'Explaining the changes…' : '';
                notesStatus.className = 'code-notes-status' + (pr.explaining ? ' working' : '');
                info.title = pr.summary || '';
                info.hidden = !pr.summary;
                // A new diff (the change moved on) needs its own explanation.
                const requestKey = currentFile + '|' + pr.diffKey;
                if (!pr.explained && !pr.explaining && prRequested !== requestKey) {
                    prRequested = requestKey;
                    postCode('explainPR');
                }
                track.textContent = '';
                marked = [];
                pr.added.forEach(function(r) { marked.push({ start: r[0], end: r[1], level: 'added', title: 'Added' }); });
                pr.removed.forEach(function(r) {
                    marked.push({ start: r[0], end: r[0], level: 'removed', title: r[1] + (r[1] === 1 ? ' line' : ' lines') + ' removed' });
                });
                pr.changes.forEach(function(change) {
                    const color = levelColors[change.kind] || levelColors.changed;
                    const span = document.createElement('div'); span.className = 'code-note-span';
                    span.style.background = color;
                    const card = document.createElement('div'); card.className = 'code-note';
                    card.dataset.start = change.start; card.dataset.end = change.end;
                    card.style.borderLeftColor = color;
                    card.style.setProperty('--note-color', color);
                    const head = document.createElement('div'); head.className = 'code-note-title';
                    head.textContent = change.title;
                    const meta = document.createElement('span'); meta.className = 'code-note-meta';
                    meta.textContent = 'L' + change.start + (change.end !== change.start ? '–' + change.end : '') + (change.kind ? ' · ' + change.kind : '');
                    head.appendChild(meta);
                    const body = document.createElement('div'); body.className = 'code-note-body';
                    body.textContent = change.why || (pr.explaining ? 'Explaining…' : '');
                    card.appendChild(head); card.appendChild(body);
                    if (change.diff && change.diff.length) {
                        const diff = document.createElement('pre'); diff.className = 'code-note-diff';
                        change.diff.forEach(function(line) {
                            const row = document.createElement('div');
                            row.className = line[0] === '+' ? 'add' : line[0] === '-' ? 'del' : '';
                            row.textContent = line;
                            diff.appendChild(row);
                        });
                        card.appendChild(diff);
                    }
                    card.title = change.title + '\n\n' + (change.why || '');
                    card.onclick = function() { if (viewer) viewer.gotoLine(change.start, change.end); };
                    card.ondblclick = function() { zoomToSection(change.start, change.end); };
                    track.appendChild(span); track.appendChild(card);
                });
                renderBands();
                renderPRLegend(pr);
                queueLayout();
            }

            function renderPRLegend(pr) {
                legend.textContent = '';
                legend.hidden = notes.hidden;
                const title = document.createElement('b'); title.textContent = pr.title;
                legend.appendChild(title);
                const counts = document.createElement('span');
                counts.textContent = ' +' + pr.additions + ' −' + pr.deletions + ' · ' + pr.changes.length + (pr.changes.length === 1 ? ' change' : ' changes');
                legend.appendChild(counts);
                ['added', 'changed', 'removed'].forEach(function(kind) {
                    const key = document.createElement('span'); key.className = 'code-legend-key';
                    key.style.color = levelColors[kind]; key.textContent = ' ● ' + kind;
                    legend.appendChild(key);
                });
                if (pr.summary) {
                    const p = document.createElement('div'); p.className = 'code-pr-summary'; p.textContent = pr.summary;
                    legend.appendChild(p);
                }
                if (pr.remapped || pr.reviewOutdated) {
                    const note = document.createElement('div'); note.className = 'code-pr-summary code-pr-note';
                    note.textContent = pr.remapped
                        ? 'The file differs from this version of the change: lines are matched by content; the change is being read again.'
                        : 'The code changed after the review — Review again in the PR X-Ray.';
                    legend.appendChild(note);
                }
            }

            /** Swift → JS: notes for the file in the viewer (CodeExplainStore payload). */
            const tempForm = notes.querySelector('.code-temp-filter');
            let pendingTemp = null;       // a one-off filter just typed here becomes the lens
            let lensBeforeTemp = 'explain';
            tempForm.addEventListener('submit', function(e) {
                e.preventDefault();
                const text = tempForm.querySelector('input').value.trim();
                if (lens.value.indexOf('tmp-') !== 0) lensBeforeTemp = lens.value;
                pendingTemp = text || null;
                postCode('tempFilter', { criterion: text });
            });
            tempForm.querySelector('button').addEventListener('click', function() {
                tempForm.querySelector('input').value = '';
                pendingTemp = null;
                postCode('tempFilter', { criterion: '' });
            });

            window.setCodeNotes = function(payload) {
                notesState = payload || null;
                const temp = ((notesState && notesState.filters) || []).find(function(f) { return f.id.indexOf('tmp-') === 0; });
                tempForm.querySelector('button').hidden = !temp;
                if (temp && document.activeElement !== tempForm.querySelector('input')) tempForm.querySelector('input').value = temp.criterion;
                if (!temp && lens.value.indexOf('tmp-') === 0) { renderLensOptions(); lens.value = lensBeforeTemp; }
                if (pendingTemp && temp && temp.criterion === pendingTemp) { pendingTemp = null; renderLensOptions(); lens.value = temp.id; }
                if (explainOnOpen && notesState) {
                    explainOnOpen = false;
                    if (!notesState.explanation && !notesState.working) { notesHidden = false; postCode('explain'); }
                }
                if (pendingLens && notesState) {
                    const made = (notesState.filters || []).find(function(f) { return f.criterion === pendingLens; });
                    if (made) { pendingLens = null; renderLensOptions(); lens.value = made.id; }
                }
                renderNotes();
            };

            documentButton.addEventListener('click', function() { postCode('notesView', { show: false }); });
            docExplainButton.addEventListener('click', function() {
                explainOnOpen = true;
                notesHidden = false;
                postCode('notesView', { show: true });
            });
            explainButton.addEventListener('click', function() {
                notesHidden = false;
                if (notesState && notesState.explanation) renderNotes(); else postCode('explain');
            });
            notes.querySelector('.code-notes-redo').addEventListener('click', function() { postCode('explain'); });
            notes.querySelector('.code-notes-close').addEventListener('click', function() { notesHidden = true; renderNotes(); });
            const newFilter = notes.querySelector('.code-new-filter');
            lens.addEventListener('change', function() {
                if (lens.value === '__new__') {
                    lens.value = 'explain';
                    newFilter.hidden = false;
                    newFilter.querySelector('input').focus();
                    return;
                }
                renderNotes();
            });
            newFilter.addEventListener('submit', function(e) {
                e.preventDefault();
                const text = newFilter.querySelector('input').value.trim();
                if (!text) return;
                postCode('createFilter', { name: '', criterion: text });
                newFilter.querySelector('input').value = '';
                newFilter.hidden = true;
                pendingLens = text;
            });
            window.addEventListener('resize', queueLayout);

            window.codeViewOpenSearch = function() {
                if (viewer) viewer.openSearch();
            };

            // Other content types take over the editor area.
            const origSetContent = window.setContent;
            window.setContent = function(markdown) {
                window.leaveCodeView();
                origSetContent(markdown);
            };
            const origSetStructured = window.setStructuredContent;
            window.setStructuredContent = function(content, fileType) {
                window.leaveCodeView();
                origSetStructured(content, fileType);
            };
            const origSetTheme = window.setTheme;
            window.setTheme = function(theme) {
                origSetTheme(theme);
                if (viewer) viewer.setTheme(theme === 'dark');
            };
        })();
