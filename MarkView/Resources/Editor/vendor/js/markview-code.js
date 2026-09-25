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
                if (window.closeCodeFloating) window.closeCodeFloating();
                container.classList.remove('visible');
                document.body.classList.remove('code-mode');
                document.getElementById('wysiwyg-toolbar').style.display = '';
            };

            /** Show `text` read-only with syntax highlighting for `language`. */
            window.setCodeContent = function(text, language, fileName) {
                if (window.closeCodeFloating) window.closeCodeFloating();
                if (fileName !== currentFile && typeof closeAI === 'function') closeAI();
                currentFile = fileName || null;
                enterCodeView(language);
                documentButton.hidden = language !== 'markdown';
                main.classList.toggle('code-md', language === 'markdown');
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

            // ------------------------------------------------------------ navigation
            // ⌘-click a symbol: its definition (on a declaration: its usages); ⌥⌘-click, ⇧F12
            // or the context menu: every usage. Several results open a list to pick from;
            // ◀ ▶ (⌘[ ⌘]) walk back and forward through the jumps. Swift answers through
            // window.onCodeNavEvent.

            const navBar = document.createElement('div'); navBar.className = 'code-nav';
            navBar.innerHTML = '<button data-nav="back" title="Back (⌘[)" disabled>◀</button>'
                + '<button data-nav="forward" title="Forward (⌘])" disabled>▶</button>';
            main.appendChild(navBar);
            const linkHover = document.createElement('div'); linkHover.className = 'code-link-hover'; linkHover.hidden = true;
            document.body.appendChild(linkHover);
            let peek = null;          // the open result list
            let menu = null;          // the open context menu

            /** The CodeMirror view when code (not formatted markdown) is shown. */
            function cmView() {
                return viewer && viewer === codeViewer && codeViewer && codeViewer.view && state.mode === 'code' ? codeViewer.view : null;
            }

            /** The word under a mouse position: {name, line, from, to} or null. */
            function wordAtPoint(x, y) {
                const view = cmView();
                if (!view) return null;
                const pos = view.posAtCoords({ x: x, y: y }, false);
                if (pos == null) return null;
                return wordAtPos(view, pos);
            }

            function wordAtPos(view, pos) {
                const range = view.state.wordAt(pos);
                if (!range) return null;
                const name = view.state.sliceDoc(range.from, range.to);
                if (!/^[A-Za-z_$][\w$]*$/.test(name) || name.length < 2) return null;
                return { name: name, line: view.state.doc.lineAt(range.from).number, from: range.from, to: range.to };
            }

            /** The line the cursor is on (where "back" returns to). */
            function cursorLine() {
                const view = cmView();
                return view ? view.state.doc.lineAt(view.state.selection.main.head).number : 1;
            }

            function showLink(word) {
                const view = cmView();
                const a = word && view ? view.coordsAtPos(word.from) : null;
                const b = word && view ? view.coordsAtPos(word.to) : null;
                if (!a || !b) { linkHover.hidden = true; return; }
                linkHover.hidden = false;
                linkHover.style.left = a.left + 'px';
                linkHover.style.top = (a.bottom - 2) + 'px';
                linkHover.style.width = Math.max(4, b.left - a.left) + 'px';
            }

            main.addEventListener('mousemove', function(e) {
                if (!e.metaKey) { if (!linkHover.hidden) linkHover.hidden = true; main.classList.remove('code-linking'); return; }
                const word = wordAtPoint(e.clientX, e.clientY);
                main.classList.toggle('code-linking', !!word);
                showLink(word);
            });
            main.addEventListener('mouseleave', function() { linkHover.hidden = true; main.classList.remove('code-linking'); });
            document.addEventListener('keyup', function(e) {
                if (e.key === 'Meta') { linkHover.hidden = true; main.classList.remove('code-linking'); }
            });
            main.addEventListener('scroll', function() { linkHover.hidden = true; }, true);

            let peekAnchor = null;    // where the list opens: under the word that asked for it

            let navLine = null;       // the line the lookup started on (where "back" returns)

            function anchorAt(word) {
                navLine = word ? word.line : null;
                const view = cmView();
                peekAnchor = word && view ? view.coordsAtPos(word.from) : null;
            }

            function goToDefinition(word) {
                if (!word) return;
                anchorAt(word);
                postCode('navDefinition', { name: word.name, line: word.line });
            }
            function findUsages(word) {
                if (!word) return;
                anchorAt(word);
                postCode('navUsages', { name: word.name, line: word.line });
            }

            // Capture phase: before CodeMirror turns the click into a selection.
            main.addEventListener('mousedown', function(e) {
                if (!e.metaKey || e.button !== 0) return;
                const word = wordAtPoint(e.clientX, e.clientY);
                if (!word) return;
                e.preventDefault();
                e.stopPropagation();
                linkHover.hidden = true;
                if (e.altKey) findUsages(word); else goToDefinition(word);
            }, true);

            navBar.addEventListener('click', function(e) {
                const nav = e.target.getAttribute && e.target.getAttribute('data-nav');
                if (nav === 'back') postCode('navBack', { line: cursorLine() });
                if (nav === 'forward') postCode('navForward', { line: cursorLine() });
            });

            container.addEventListener('keydown', function(e) {
                if (!container.classList.contains('visible')) return;
                const view = cmView();
                if (e.key === 'Escape' && (peek || menu || aiPanel)) {
                    closePeek(); closeMenu();
                    if (aiPanel && !aiPanel.contains(document.activeElement)) closeAI();
                    return;
                }
                if (e.key === 'F12' && view) {
                    e.preventDefault();
                    const word = wordAtPos(view, view.state.selection.main.head);
                    if (e.shiftKey) findUsages(word); else goToDefinition(word);
                } else if (e.metaKey && (e.key === '[' || e.key === ']')) {
                    e.preventDefault();
                    postCode(e.key === '[' ? 'navBack' : 'navForward', { line: cursorLine() });
                }
            });

            function closePeek() { if (peek) { peek.remove(); peek = null; } }
            function closeMenu() { if (menu) { menu.remove(); menu = null; } }
            document.addEventListener('mousedown', function(e) {
                if (peek && !peek.contains(e.target)) closePeek();
                if (menu && !menu.contains(e.target)) closeMenu();
            });

            function escapeHTML(text) {
                return String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
            }

            /** The line text with `name` marked as a word. */
            function markName(text, name) {
                const re = new RegExp('(^|[^\\w$])(' + name.replace(/\$/g, '\\$') + ')(?![\\w$])', 'g');
                return escapeHTML(text).replace(re, '$1<mark>$2</mark>');
            }

            /** A list of definitions or usages, grouped by file; click (or ↵) opens one. */
            function showPeek(event) {
                closePeek(); closeMenu();
                const results = event.results || [];
                peek = document.createElement('div'); peek.className = 'code-peek'; peek.tabIndex = -1;
                const defs = results.filter(function(r) { return r.kind !== 'usage'; }).length;
                const uses = results.length - defs;
                const title = event.type === 'definitions'
                    ? results.length + ' definitions of ' + event.name
                    : uses + (uses === 1 ? ' usage' : ' usages') + ' of ' + event.name + (defs ? ' · ' + defs + (defs === 1 ? ' definition' : ' definitions') : '');
                peek.innerHTML = '<div class="code-peek-head"><b></b><span></span><button title="Close (Esc)">✕</button></div><div class="code-peek-list"></div>';
                peek.querySelector('b').textContent = title + (event.truncated ? ' (first matches)' : '');
                peek.querySelector('span').textContent = event.note || '';
                peek.querySelector('button').onclick = closePeek;
                const list = peek.querySelector('.code-peek-list');
                if (!results.length) {
                    const empty = document.createElement('div'); empty.className = 'code-peek-empty';
                    empty.textContent = 'Nothing found in the project.';
                    list.appendChild(empty);
                }
                let lastPath = null;
                const rows = [];
                results.forEach(function(r) {
                    if (r.path !== lastPath) {
                        lastPath = r.path;
                        const file = document.createElement('div'); file.className = 'code-peek-file';
                        const count = results.filter(function(x) { return x.path === r.path; }).length;
                        file.innerHTML = '<span class="name"></span><span class="dir"></span><span class="count"></span>';
                        const slash = r.path.lastIndexOf('/');
                        file.querySelector('.name').textContent = r.path.slice(slash + 1);
                        file.querySelector('.dir').textContent = slash > 0 ? r.path.slice(0, slash) : '';
                        file.querySelector('.count').textContent = count;
                        file.title = r.path;
                        list.appendChild(file);
                    }
                    const row = document.createElement('div'); row.className = 'code-peek-row ' + r.kind;
                    row.innerHTML = '<span class="ln"></span><span class="tx"></span>';
                    row.querySelector('.ln').textContent = r.line;
                    row.querySelector('.tx').innerHTML = (r.kind !== 'usage' ? '<i>' + r.kind + '</i> ' : '') + markName(r.text, event.name);
                    row.title = r.path + ':' + r.line;
                    row.onclick = function() { openResult(r); };
                    list.appendChild(row);
                    rows.push({ el: row, r: r });
                });
                // Below the cursor's line when there is room, otherwise centred.
                const view = cmView();
                const at = peekAnchor || (view ? view.coordsAtPos(view.state.selection.main.head) : null);
                const box = main.getBoundingClientRect();
                peek.style.left = Math.max(box.left + 12, Math.min(at ? at.left - 40 : box.left + 60, box.right - 620)) + 'px';
                const top = at ? at.bottom + 6 : box.top + 60;
                peek.style.top = (top + 320 > window.innerHeight ? Math.max(box.top + 8, window.innerHeight - 340) : top) + 'px';
                document.body.appendChild(peek);
                let selected = 0;
                function select(i) {
                    if (!rows.length) return;
                    selected = (i + rows.length) % rows.length;
                    rows.forEach(function(x, j) { x.el.classList.toggle('selected', j === selected); });
                    rows[selected].el.scrollIntoView({ block: 'nearest' });
                }
                select(0);
                peek.addEventListener('keydown', function(e) {
                    if (e.key === 'ArrowDown') { e.preventDefault(); select(selected + 1); }
                    else if (e.key === 'ArrowUp') { e.preventDefault(); select(selected - 1); }
                    else if (e.key === 'Enter' && rows[selected]) { e.preventDefault(); openResult(rows[selected].r); }
                    else if (e.key === 'Escape') { e.preventDefault(); closePeek(); }
                });
                peek.focus();
            }

            function openResult(r) {
                closePeek();
                postCode('navOpen', { path: r.path, target: r.line, line: navLine || cursorLine() });
            }

            // Right click: the navigation and AI actions for the word and the selection.
            main.addEventListener('contextmenu', function(e) {
                const view = cmView();
                if (!view) return;
                e.preventDefault();
                closeMenu(); closePeek();
                const word = wordAtPoint(e.clientX, e.clientY);
                const sel = view.state.selection.main;
                menu = document.createElement('div'); menu.className = 'code-menu';
                function item(label, key, action, disabled) {
                    const el = document.createElement('button');
                    el.innerHTML = '<span></span><kbd></kbd>';
                    el.firstChild.textContent = label; el.lastChild.textContent = key || '';
                    el.disabled = !!disabled;
                    el.onclick = function() { closeMenu(); action(); };
                    menu.appendChild(el);
                }
                const name = word ? '“' + word.name + '”' : '';
                item('Go to Definition ' + name, '⌘-click', function() { goToDefinition(word); }, !word);
                item('Find Usages ' + name, '⌥⌘-click', function() { findUsages(word); }, !word);
                menu.appendChild(document.createElement('hr'));
                item('✦ Explain with AI — everything related ' + name, '', function() {
                    postCode('explainSymbol', { name: word.name, line: word.line });
                }, !word);
                item(sel.empty ? '✦ Ask AI about this line' : '✦ Ask AI about the selection', '', function() {
                    openAI(selectionRange(e.clientY));
                });
                item('Back', '⌘[', function() { postCode('navBack', { line: cursorLine() }); }, navBar.firstChild.disabled);
                menu.style.left = Math.min(e.clientX, window.innerWidth - 260) + 'px';
                menu.style.top = Math.min(e.clientY, window.innerHeight - 170) + 'px';
                document.body.appendChild(menu);
            });

            // ------------------------------------------------------------ AI on a selection
            // Select code → "✦ Ask AI": Explain / Find bugs / Improve or an own question.
            // Answers stream in as Markdown; follow-up questions keep the conversation.

            const askButton = document.createElement('button'); askButton.className = 'code-ask-btn';
            askButton.textContent = '✦ Ask AI'; askButton.title = 'Ask the AI about the selected code'; askButton.hidden = true;
            document.body.appendChild(askButton);
            let aiPanel = null;
            let ai = null;           // {id, range, turns: [{q, a, done, error, activity}]}
            // AI text never runs as HTML (the document renderer allows HTML; this one does not).
            const aiMd = window.markdownit ? window.markdownit({ html: false, linkify: true, breaks: false }) : null;

            /** Lines of the selection, or the line at `y` (the mouse) / the cursor's line. */
            function selectionRange(y) {
                const view = cmView();
                if (!view) return null;
                const doc = view.state.doc;
                const sel = view.state.selection.main;
                let from = sel.from, to = sel.to;
                if (sel.empty) {
                    const pos = y != null ? view.posAtCoords({ x: view.contentDOM.getBoundingClientRect().left + 40, y: y }, false) : null;
                    const line = doc.lineAt(pos != null ? pos : sel.head);
                    from = line.from; to = line.to;
                }
                const start = doc.lineAt(from).number, end = doc.lineAt(to).number;
                return { start: start, end: end, text: view.state.sliceDoc(from, to) };
            }

            function placeAskButton() {
                const view = cmView();
                if (!view || aiPanel) { askButton.hidden = true; return; }
                const sel = view.state.selection.main;
                if (sel.empty || view.state.sliceDoc(sel.from, sel.to).trim().length < 2) { askButton.hidden = true; return; }
                const at = view.coordsAtPos(sel.to) || view.coordsAtPos(sel.from);
                if (!at) { askButton.hidden = true; return; }
                const box = main.getBoundingClientRect();
                askButton.hidden = false;
                askButton.style.left = Math.min(at.right + 8, box.right - 110) + 'px';
                askButton.style.top = Math.max(box.top + 4, Math.min(at.bottom + 4, box.bottom - 60)) + 'px';
            }
            main.addEventListener('mouseup', function() { setTimeout(placeAskButton, 0); });
            main.addEventListener('keyup', function(e) { if (e.shiftKey || e.key === 'Shift') placeAskButton(); });
            main.addEventListener('scroll', function() { askButton.hidden = true; }, true);
            askButton.addEventListener('mousedown', function(e) { e.preventDefault(); });   // keep the selection
            askButton.addEventListener('click', function() { openAI(selectionRange()); });

            function openAI(range) {
                if (!range || !range.text.trim()) return;
                askButton.hidden = true;
                closeAI();
                ai = { id: 'ai-' + Date.now(), range: range, turns: [] };
                aiPanel = document.createElement('div'); aiPanel.className = 'code-ai';
                aiPanel.innerHTML = '<div class="code-ai-head"><b>✦ Ask AI</b><span class="code-ai-range"></span>'
                    + '<button class="code-ai-close" title="Close">✕</button></div>'
                    + '<pre class="code-ai-snippet"></pre>'
                    + '<div class="code-ai-quick"><button data-q="Explain what this code does, step by step, and why.">Explain</button>'
                    + '<button data-q="Review this code for bugs, edge cases and risks. For each problem: how it shows up and how to fix it.">Find bugs</button>'
                    + '<button data-q="How could this code be simpler, clearer or faster? Show the improved version.">Improve</button>'
                    + '<button data-q="Where and how is this code used in the project, and what depends on it?">Where used</button></div>'
                    + '<div class="code-ai-log"></div>'
                    + '<form class="code-ai-form"><textarea rows="2" placeholder="Ask about this code… (↵ to send, ⇧↵ new line)"></textarea>'
                    + '<button type="submit">Ask</button></form>';
                aiPanel.querySelector('.code-ai-range').textContent = 'L' + range.start + (range.end !== range.start ? '–' + range.end : '')
                    + (currentFile ? ' · ' + currentFile : '');
                const lines = range.text.split('\n');
                aiPanel.querySelector('.code-ai-snippet').textContent = lines.slice(0, 6).join('\n') + (lines.length > 6 ? '\n…' : '');
                aiPanel.querySelector('.code-ai-close').onclick = closeAI;
                aiPanel.querySelectorAll('.code-ai-quick button').forEach(function(b) {
                    b.onclick = function() { askAI(b.getAttribute('data-q'), b.textContent); };
                });
                const form = aiPanel.querySelector('.code-ai-form');
                const input = form.querySelector('textarea');
                form.addEventListener('submit', function(e) {
                    e.preventDefault();
                    const q = input.value.trim();
                    if (!q) return;
                    input.value = '';
                    askAI(q, q);
                });
                input.addEventListener('keydown', function(e) {
                    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); form.requestSubmit(); }
                    if (e.key === 'Escape') { e.preventDefault(); closeAI(); }
                });
                main.appendChild(aiPanel);
                input.focus();
            }

            function closeAI() {
                if (ai) {
                    const last = ai.turns[ai.turns.length - 1];
                    if (last && !last.done) postCode('askStop', { id: ai.id });
                }
                if (aiPanel) aiPanel.remove();
                aiPanel = null; ai = null;
            }

            function askAI(question, label) {
                if (!ai) return;
                const last = ai.turns[ai.turns.length - 1];
                if (last && !last.done) return;   // one question at a time
                const history = ai.turns.filter(function(t) { return t.done && !t.error; })
                    .map(function(t) { return { q: t.q, a: t.a }; });
                ai.turns.push({ q: question, label: label, a: '', done: false, activity: 'Thinking…' });
                renderAI();
                postCode('askAI', { id: ai.id, question: question, text: ai.range.text, start: ai.range.start,
                                    end: ai.range.end, history: history });
            }

            /** `path:line` in an answer opens that place. */
            function linkPlaces(el) {
                el.querySelectorAll('code').forEach(function(code) {
                    const m = code.textContent.match(/^([\w./@\-\[\]]+\.[A-Za-z0-9]+):(\d+)(?:[-–](\d+))?$/);
                    if (!m || code.closest('pre')) return;
                    code.classList.add('code-ai-place');
                    code.title = 'Open ' + m[1] + ' at line ' + m[2];
                    code.onclick = function() { postCode('navOpen', { path: m[1], target: +m[2], line: cursorLine() }); };
                });
            }

            function renderAI() {
                if (!aiPanel || !ai) return;
                const log = aiPanel.querySelector('.code-ai-log');
                log.textContent = '';
                ai.turns.forEach(function(turn, i) {
                    const q = document.createElement('div'); q.className = 'code-ai-q'; q.textContent = turn.label;
                    const a = document.createElement('div'); a.className = 'code-ai-a markdown-body';
                    if (turn.a) {
                        a.innerHTML = aiMd ? aiMd.render(turn.a) : escapeHTML(turn.a).replace(/\n/g, '<br>');
                        linkPlaces(a);
                    }
                    if (!turn.done) {
                        const status = document.createElement('div'); status.className = 'code-ai-status';
                        status.innerHTML = '<span class="code-ai-dot"></span><span></span><button>Stop</button>';
                        status.children[1].textContent = turn.activity || 'Writing…';
                        status.querySelector('button').onclick = function() { postCode('askStop', { id: ai.id }); };
                        a.appendChild(status);
                    } else if (turn.error || turn.stopped) {
                        const status = document.createElement('div'); status.className = 'code-ai-status error';
                        status.textContent = turn.error ? 'Failed: ' + turn.error : 'Stopped.';
                        a.appendChild(status);
                    }
                    log.appendChild(q); log.appendChild(a);
                });
                aiPanel.querySelectorAll('.code-ai-quick button, .code-ai-form button').forEach(function(b) {
                    const last = ai.turns[ai.turns.length - 1];
                    b.disabled = !!(last && !last.done);
                });
                log.scrollTop = log.scrollHeight;
            }

            function receiveAnswer(event) {
                if (!ai || event.id !== ai.id) return;
                const turn = ai.turns[ai.turns.length - 1];
                if (!turn) return;
                if (event.text !== undefined && (event.text || event.done)) turn.a = event.text || turn.a;
                if (event.activity) turn.activity = event.activity;
                else if (event.text) turn.activity = 'Writing…';
                if (event.done) { turn.done = true; turn.error = event.error || null; turn.stopped = !!event.stopped; }
                renderAI();
            }

            /** Swift → JS: navigation results, history state and AI answers. */
            window.onCodeNavEvent = function(event) {
                if (!event) return;
                if (event.type === 'state') {
                    navBar.querySelector('[data-nav="back"]').disabled = !event.back;
                    navBar.querySelector('[data-nav="forward"]').disabled = !event.forward;
                    navBar.classList.toggle('active', !!(event.back || event.forward));
                } else if (event.type === 'definitions' || event.type === 'usages') {
                    showPeek(event);
                } else if (event.type === 'answer') {
                    receiveAnswer(event);
                }
            };

            /** Hide lists, menus and the Ask button (another file or view is shown). */
            window.closeCodeFloating = function() {
                closePeek(); closeMenu();
                askButton.hidden = true; linkHover.hidden = true;
            };

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
